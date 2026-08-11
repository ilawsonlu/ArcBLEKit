import Foundation

/// A Bluetooth Low Energy central that exposes CoreBluetooth operations through Swift Concurrency.
///
/// Keep a client alive for the duration of the app's BLE workflow. A client manages one active
/// scan at a time and creates ``PeripheralSession`` instances for connected peripherals.
public final class BLEClient: @unchecked Sendable {
    private struct ActiveConnection {
        let id: UUID
        let cancel: @Sendable () -> Void
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

    let central: CentralManaging
    private let lock = NSLock()
    private let scanLock = NSLock()
    private let connectionLock = NSLock()
    private let stateLock = NSLock()
    private var peripheralsByIdentifier: [UUID: PeripheralRepresenting] = [:]
    private var sessionsByIdentifier: [UUID: PeripheralSession] = [:]
    private var activeScanID: UUID?
    private var activeScanContinuation: AsyncThrowingStream<BLEDevice, Error>.Continuation?
    private var activeConnection: ActiveConnection?
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
            self?.publishBluetoothState(state)
        }
        self.central.onDisconnect = { [weak self] peripheral, error in
            self?.session(identifier: peripheral.identifier)?.handleDisconnect(error: error)
        }
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
        switch central.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw BLEError.bluetoothUnauthorized
        case .unsupported:
            throw BLEError.bluetoothUnavailable
        case .poweredOff:
            throw BLEError.bluetoothPoweredOff
        case .unknown, .resetting:
            throw BLEError.bluetoothUnavailable
        }
    }

    func startScan(
        id: UUID,
        filter: ScanFilter,
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
            withServices: filter.serviceUUIDs.isEmpty ? nil : filter.serviceUUIDs
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
        onSuperseded: @escaping @Sendable () -> Void,
        onConnect: @escaping @Sendable (PeripheralRepresenting) -> Void,
        onFailToConnect: @escaping @Sendable (PeripheralRepresenting, Error?) -> Void
    ) {
        connectionLock.lock()
        let previousConnection = activeConnection
        activeConnection = ActiveConnection(id: id, cancel: onSuperseded)
        central.onConnect = { [weak self] connectedPeripheral in
            guard self?.isActiveConnection(id: id) == true else { return }
            onConnect(connectedPeripheral)
        }
        central.onFailToConnect = { [weak self] failedPeripheral, error in
            guard self?.isActiveConnection(id: id) == true else { return }
            onFailToConnect(failedPeripheral, error)
        }
        connectionLock.unlock()

        previousConnection?.cancel()

        guard isActiveConnection(id: id) else {
            return
        }

        central.connect(peripheral)
    }

    func isActiveConnection(id: UUID) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return activeConnection?.id == id
    }

    func finishConnection(id: UUID) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        guard activeConnection?.id == id else {
            return false
        }

        activeConnection = nil
        central.onConnect = nil
        central.onFailToConnect = nil
        return true
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
