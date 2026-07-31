import Foundation

final class NotificationRegistry {
    typealias Continuation = AsyncThrowingStream<Data, Error>.Continuation

    private struct Entry {
        var characteristic: CharacteristicRepresenting
        var continuations: [UUID: Continuation]
    }

    private let lock = NSLock()
    private var entries: [GATTCharacteristicID: Entry] = [:]

    func hasSubscribers(for id: GATTCharacteristicID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.continuations.isEmpty == false
    }

    func add(
        _ continuation: Continuation,
        subscriberID: UUID,
        characteristic: CharacteristicRepresenting,
        for id: GATTCharacteristicID
    ) {
        lock.lock()
        var entry = entries[id] ?? Entry(
            characteristic: characteristic,
            continuations: [:]
        )
        entry.characteristic = characteristic
        entry.continuations[subscriberID] = continuation
        entries[id] = entry
        lock.unlock()
    }

    func remove(
        subscriberID: UUID,
        from id: GATTCharacteristicID
    ) -> CharacteristicRepresenting? {
        lock.lock()
        guard var entry = entries[id] else {
            lock.unlock()
            return nil
        }

        entry.continuations[subscriberID] = nil
        guard entry.continuations.isEmpty else {
            entries[id] = entry
            lock.unlock()
            return nil
        }

        entries[id] = nil
        lock.unlock()
        return entry.characteristic
    }

    func activeIDs() -> [GATTCharacteristicID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.keys)
    }

    func update(
        characteristic: CharacteristicRepresenting,
        for id: GATTCharacteristicID
    ) {
        lock.lock()
        if var entry = entries[id] {
            entry.characteristic = characteristic
            entries[id] = entry
        }
        lock.unlock()
    }

    func yield(_ data: Data, for id: GATTCharacteristicID) {
        lock.lock()
        let continuations: [Continuation]
        if let entry = entries[id] {
            continuations = Array(entry.continuations.values)
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
            continuations = Array(entry.continuations.values)
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
        let continuations = entries.values.flatMap {
            Array($0.continuations.values)
        }
        entries.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }
}
