import Foundation

final class NotificationRegistry {
    typealias Continuation = AsyncThrowingStream<Data, Error>.Continuation

    struct Snapshot {
        let id: GATTCharacteristicID
        let generation: UUID
        let revision: UUID
        let configuration: NotificationSubscriptionConfiguration
        let characteristic: CharacteristicRepresenting
        let setupState: NotificationSetupState
    }

    private struct Subscriber {
        let continuation: Continuation
        let configuration: NotificationSubscriptionConfiguration
    }

    private struct Entry {
        let generation: UUID
        var revision: UUID
        var characteristic: CharacteristicRepresenting
        var setupState: NotificationSetupState
        var subscribers: [UUID: Subscriber]

        func snapshot(for id: GATTCharacteristicID) -> Snapshot {
            let configuration = subscribers.values.reduce(
                NotificationSubscriptionConfiguration(
                    allowUnsupportedProperties: true,
                    discoveryMode: .targeted
                )
            ) { $0.merging($1.configuration) }
            return Snapshot(
                id: id,
                generation: generation,
                revision: revision,
                configuration: configuration,
                characteristic: characteristic,
                setupState: setupState
            )
        }
    }

    private let lock = NSLock()
    private var entries: [GATTCharacteristicID: Entry] = [:]
    private var terminalError: Error?

    func hasSubscribers(for id: GATTCharacteristicID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.subscribers.isEmpty == false
    }

    func add(
        _ continuation: Continuation,
        subscriberID: UUID,
        characteristic: CharacteristicRepresenting,
        configuration: NotificationSubscriptionConfiguration,
        setupState: NotificationSetupState,
        for id: GATTCharacteristicID
    ) {
        lock.lock()
        if let error = terminalError {
            lock.unlock()
            continuation.finish(throwing: error)
            return
        }
        var entry = entries[id] ?? Entry(
            generation: UUID(),
            revision: UUID(),
            characteristic: characteristic,
            setupState: setupState,
            subscribers: [:]
        )
        entry.revision = UUID()
        entry.characteristic = characteristic
        entry.setupState = setupState
        entry.subscribers[subscriberID] = Subscriber(
            continuation: continuation,
            configuration: configuration
        )
        entries[id] = entry
        lock.unlock()
    }

    func remove(
        subscriberID: UUID,
        from id: GATTCharacteristicID
    ) -> CharacteristicRepresenting? {
        lock.lock()
        guard var entry = entries[id],
              entry.subscribers.removeValue(forKey: subscriberID) != nil else {
            lock.unlock()
            return nil
        }

        entry.revision = UUID()
        guard entry.subscribers.isEmpty else {
            entries[id] = entry
            lock.unlock()
            return nil
        }

        entries[id] = nil
        lock.unlock()
        return entry.setupState == .inactive ? nil : entry.characteristic
    }

    func activeIDs() -> [GATTCharacteristicID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.keys)
    }

    func snapshots() -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { $0.value.snapshot(for: $0.key) }
    }

    func snapshot(for id: GATTCharacteristicID) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.snapshot(for: id)
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return matches(snapshot)
    }

    /// Publish the new characteristic before awaiting setup, so last-consumer cleanup uses it.
    func beginSetup(
        characteristic: CharacteristicRepresenting,
        for snapshot: Snapshot
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard matches(snapshot) else { return false }
        entries[snapshot.id]?.characteristic = characteristic
        entries[snapshot.id]?.setupState = .unconfirmed
        return true
    }

    @discardableResult
    func update(
        characteristic: CharacteristicRepresenting,
        setupState: NotificationSetupState,
        for snapshot: Snapshot
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard matches(snapshot) else { return false }
        entries[snapshot.id]?.characteristic = characteristic
        entries[snapshot.id]?.setupState = setupState
        return true
    }

    func invalidateSetups() {
        lock.lock()
        for id in Array(entries.keys) {
            entries[id]?.revision = UUID()
            entries[id]?.setupState = .inactive
        }
        lock.unlock()
    }

    // Caller holds lock. Revisions reject changed consumers; generations reject replaced channels.
    private func matches(_ snapshot: Snapshot) -> Bool {
        entries[snapshot.id]?.generation == snapshot.generation &&
            entries[snapshot.id]?.revision == snapshot.revision
    }

    func yield(_ data: Data, for id: GATTCharacteristicID) {
        lock.lock()
        let continuations: [Continuation]
        if let entry = entries[id] {
            continuations = entry.subscribers.values.map(\.continuation)
        } else {
            continuations = []
        }
        lock.unlock()

        for continuation in continuations {
            continuation.yield(data)
        }
    }

    func finish(id: GATTCharacteristicID, throwing error: Error) {
        lock.lock()
        let continuations: [Continuation]
        if let entry = entries.removeValue(forKey: id) {
            continuations = entry.subscribers.values.map(\.continuation)
        } else {
            continuations = []
        }
        lock.unlock()

        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }

    func finishAll(throwing error: Error) {
        lock.lock()
        terminalError = error
        let continuations = entries.values.flatMap {
            $0.subscribers.values.map(\.continuation)
        }
        entries.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }
}
