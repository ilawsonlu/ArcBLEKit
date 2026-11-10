import Foundation

/// A Bluetooth Low Energy central that exposes CoreBluetooth operations through Swift Concurrency.
///
/// Keep a client alive for the duration of the app's BLE workflow. A client manages one active
/// scan at a time and creates ``PeripheralSession`` instances for connected peripherals.
public final class BLEClient: @unchecked Sendable {
    private struct ActiveConnection {
        let id: UUID
        let cancel: @Sendable () -> Void
        let fail: @Sendable (BLEError) -> Void
        let onConnect: @Sendable (PeripheralRepresenting) -> Void
        let onFailToConnect: @Sendable (PeripheralRepresenting, Error?) -> Void
    }

    /// Options used to create the underlying CoreBluetooth central manager.
    public struct Configuration: Sendable {
        /// An optional CoreBluetooth restoration identifier.
        ///
        /// ArcBLEKit passes this value to CoreBluetooth, but full app-relaunch state restoration
        /// is not currently implemented.
        public var restoreIdentifier: String?

        /// Creates a client configuration.
        /// - Parameter restoreIdentifier: An optional CoreBluetooth restoration identifier.
        public init(restoreIdentifier: String? = nil) {
            self.restoreIdentifier = restoreIdentifier
        }
    }

    let eventLock = NSLock()
    // Serialize registration changes without holding the lock used by event delivery.
    let eventRegistrationLock = NSRecursiveLock()
    var eventID: UUID?
    var eventFilter: ConnectionEventFilter?
    var eventContinuation: AsyncThrowingStream<ConnectionEvent, Error>.Continuation?
    let central: CentralManaging
    private let lock = NSLock()
    private let scanLock = NSLock()
    private let connectionLock = NSLock()
    private let stateLock = NSLock()
    private var peripheralsByIdentifier: [UUID: PeripheralRepresenting] = [:]
    private var sessionsByIdentifier: [UUID: PeripheralSession] = [:]
    private var activeScanID: UUID?
    private var activeScanContinuation: AsyncThrowingStream<BLEDevice, Error>.Continuation?
    /// Pending connection attempts keyed by peripheral identifier. Each peripheral has at most one
    /// attempt; attempts for different peripherals proceed independently.
    private var activeConnections: [UUID: ActiveConnection] = [:]
    private var stateContinuations: [
        UUID: AsyncStream<BluetoothState>.Continuation
    ] = [:]

    /// The central manager's latest Bluetooth state.
    public var bluetoothState: BluetoothState {
        central.state
    }

    /// A stream that emits the current Bluetooth state immediately and every subsequent update.
    public var bluetoothStates: AsyncStream<BluetoothState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateLock.lock()
            stateContinuations[id] = continuation
            stateLock.unlock()

            continuation.yield(central.state)
            continuation.onTermination = { [weak self] _ in
                self?.removeStateContinuation(id: id)
            }
        }
    }

    /// Creates a BLE central client.
    /// - Parameter configuration: CoreBluetooth central manager configuration.
    public convenience init(configuration: Configuration = .init()) {
        self.init(central: CentralManagerBox(configuration: configuration))
    }

    init(central: CentralManaging) {
        self.central = central
        self.central.onStateChange = { [weak self] state in
            self?.refreshConnectionEventRegistration(state: state)
            self?.handleBluetoothStateChange(state)
            self?.publishBluetoothState(state)
        }
        self.central.onConnectionEvent = { [weak self] kind, peripheral in
            self?.publishConnectionEvent(kind, peripheral: peripheral)
        }
        self.central.onDisconnect = { [weak self] peripheral, error in
            self?.session(identifier: peripheral.identifier)?.handleDisconnect(error: error)
        }
    }

    deinit {
        eventContinuation?.finish()
        central.registerForConnectionEvents(matching: nil)
    }

    func remember(_ peripheral: PeripheralRepresenting) {
        lock.lock()
        defer { lock.unlock() }
        peripheralsByIdentifier[peripheral.identifier] = peripheral
    }

    func rememberedPeripheral(identifier: UUID) -> PeripheralRepresenting? {
        lock.lock()
        defer { lock.unlock() }
        return peripheralsByIdentifier[identifier]
    }

    func remember(_ session: PeripheralSession) {
        lock.lock()
        let previousSession = sessionsByIdentifier[session.device.id]
        sessionsByIdentifier[session.device.id] = session
        lock.unlock()

        if let previousSession, previousSession !== session {
            previousSession.invalidate()
        }
    }

    func session(identifier: UUID) -> PeripheralSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionsByIdentifier[identifier]
    }

    func remove(_ session: PeripheralSession) {
        lock.lock()
        if sessionsByIdentifier[session.device.id] === session {
            sessionsByIdentifier[session.device.id] = nil
        }
        lock.unlock()
    }

    func validateBluetoothReady() throws {
        if let error = Self.unavailableError(for: central.state) {
            throw error
        }
    }

    static func unavailableError(for state: BluetoothState) -> BLEError? {
        switch state {
        case .poweredOn:
            return nil
        case .unauthorized:
            return .bluetoothUnauthorized
        case .poweredOff:
            return .bluetoothPoweredOff
        case .unsupported, .unknown, .resetting:
            return .bluetoothUnavailable
        }
    }

    /// CoreBluetooth invalidates every peripheral when the central leaves `.poweredOn` without
    /// reporting individual disconnects, so end scans, pending connections, and sessions here.
    private func handleBluetoothStateChange(_ state: BluetoothState) {
        guard let error = Self.unavailableError(for: state) else {
            return
        }

        failActiveScan(with: error)
        failPendingConnections(with: error)

        lock.lock()
        let sessions = Array(sessionsByIdentifier.values)
        lock.unlock()
        for session in sessions {
            session.handleDisconnect(error: error)
        }
    }

    private func failActiveScan(with error: BLEError) {
        scanLock.lock()
        let continuation = activeScanContinuation
        if continuation != nil {
            activeScanID = nil
            activeScanContinuation = nil
            central.onDiscover = nil
        }
        scanLock.unlock()

        continuation?.finish(throwing: error)
    }

    private func failPendingConnections(with error: BLEError) {
        connectionLock.lock()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        central.onConnect = nil
        central.onFailToConnect = nil
        connectionLock.unlock()

        for connection in connections {
            connection.fail(error)
        }
    }

    /// Suspends until Bluetooth powers on, tolerating transient off and resetting states.
    ///
    /// Unlike ``waitUntilReady(timeout:)``, `.poweredOff` is not terminal, so automatic reconnect
    /// can survive the user toggling Bluetooth. An infinite timeout waits until cancellation.
    func waitForPoweredOn(timeout: TimeInterval) async throws {
        if central.state == .poweredOn {
            return
        }
        let timeoutNanoseconds = timeoutNanoseconds(timeout)
        guard timeoutNanoseconds != nil || Self.isUnlimited(timeout) else {
            throw BLEError.bluetoothReadyTimedOut
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        throw BLEError.bluetoothUnavailable
                    }
                    for await state in self.bluetoothStates {
                        try Task.checkCancellation()
                        switch state {
                        case .poweredOn:
                            return
                        case .unauthorized:
                            throw BLEError.bluetoothUnauthorized
                        case .unsupported:
                            throw BLEError.bluetoothUnavailable
                        case .poweredOff, .unknown, .resetting:
                            continue
                        }
                    }
                    throw Task.isCancelled
                        ? BLEError.operationCancelled
                        : BLEError.bluetoothUnavailable
                }

                if let timeoutNanoseconds {
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        throw BLEError.bluetoothReadyTimedOut
                    }
                }

                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch is CancellationError {
            throw BLEError.operationCancelled
        }
    }

    static func isUnlimited(_ timeout: TimeInterval) -> Bool {
        timeout == .infinity
    }

    func startScan(
        id: UUID,
        filter: ScanFilter,
        options: ScanOptions = .init(),
        continuation: AsyncThrowingStream<BLEDevice, Error>.Continuation
    ) {
        scanLock.lock()
        let previousContinuation = activeScanContinuation
        activeScanID = id
        activeScanContinuation = continuation

        central.onDiscover = { [weak self] peripheral, advertisement, rssi in
            guard let self else { return }
            guard self.isActiveScan(id: id) else { return }
            let device = BLEAdvertisementParser.makeDevice(
                peripheral: peripheral,
                advertisement: advertisement,
                rssi: rssi
            )
            guard filter.matches(device) else { return }
            self.remember(peripheral)
            continuation.yield(device)
        }

        central.scanForPeripherals(
            withServices: filter.serviceUUIDs.isEmpty ? nil : filter.serviceUUIDs,
            options: options
        )

        scanLock.unlock()

        previousContinuation?.finish()
    }

    func isActiveScan(id: UUID) -> Bool {
        scanLock.lock()
        defer { scanLock.unlock() }
        return activeScanID == id
    }

    func finishScan(id: UUID) {
        scanLock.lock()
        defer { scanLock.unlock() }

        guard activeScanID == id else {
            return
        }

        activeScanID = nil
        activeScanContinuation = nil
        central.onDiscover = nil
        central.stopScan()
    }

    func startConnection(
        id: UUID,
        peripheral: PeripheralRepresenting,
        options: ConnectionOptions,
        onSuperseded: @escaping @Sendable () -> Void,
        onBluetoothUnavailable: @escaping @Sendable (BLEError) -> Void,
        onConnect: @escaping @Sendable (PeripheralRepresenting) -> Void,
        onFailToConnect: @escaping @Sendable (PeripheralRepresenting, Error?) -> Void
    ) {
        let peripheralID = peripheral.identifier
        connectionLock.lock()
        let previousConnection = activeConnections[peripheralID]
        activeConnections[peripheralID] = ActiveConnection(
            id: id,
            cancel: onSuperseded,
            fail: onBluetoothUnavailable,
            onConnect: onConnect,
            onFailToConnect: onFailToConnect
        )
        central.onConnect = { [weak self] connectedPeripheral in
            self?.activeConnection(for: connectedPeripheral.identifier)?.onConnect(connectedPeripheral)
        }
        central.onFailToConnect = { [weak self] failedPeripheral, error in
            self?.activeConnection(for: failedPeripheral.identifier)?.onFailToConnect(failedPeripheral, error)
        }
        connectionLock.unlock()

        // Only an earlier attempt for the same peripheral is superseded.
        previousConnection?.cancel()

        guard isActiveConnection(id: id, peripheralID: peripheralID) else {
            return
        }

        central.connect(peripheral, options: options)
    }

    func isActiveConnection(id: UUID, peripheralID: UUID) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return activeConnections[peripheralID]?.id == id
    }

    func finishConnection(id: UUID, peripheralID: UUID) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        guard activeConnections[peripheralID]?.id == id else {
            return false
        }

        activeConnections[peripheralID] = nil
        if activeConnections.isEmpty {
            central.onConnect = nil
            central.onFailToConnect = nil
        }
        return true
    }

    private func activeConnection(for peripheralID: UUID) -> ActiveConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return activeConnections[peripheralID]
    }

    func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64? {
        guard timeout.isFinite, timeout > 0 else {
            return nil
        }

        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }

        return UInt64(nanoseconds)
    }

    private func publishBluetoothState(_ state: BluetoothState) {
        stateLock.lock()
        let continuations = Array(stateContinuations.values)
        stateLock.unlock()

        for continuation in continuations {
            continuation.yield(state)
        }
    }

    private func removeStateContinuation(id: UUID) {
        stateLock.lock()
        stateContinuations[id] = nil
        stateLock.unlock()
    }
}
