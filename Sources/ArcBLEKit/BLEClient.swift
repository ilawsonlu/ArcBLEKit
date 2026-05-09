import Foundation

public final class BLEClient {
    private struct ActiveConnection {
        let id: UUID
        let cancel: () -> Void
    }

    public struct Configuration: Sendable {
        public var restoreIdentifier: String?

        public init(restoreIdentifier: String? = nil) {
            self.restoreIdentifier = restoreIdentifier
        }
    }

    let central: CentralManaging
    private let lock = NSLock()
    private let scanLock = NSLock()
    private let connectionLock = NSLock()
    private var peripheralsByIdentifier: [UUID: PeripheralRepresenting] = [:]
    private var activeScanID: UUID?
    private var activeScanContinuation: AsyncStream<BLEDevice>.Continuation?
    private var activeConnection: ActiveConnection?

    public convenience init(configuration: Configuration = .init()) {
        self.init(central: CentralManagerBox(configuration: configuration))
    }

    init(central: CentralManaging) {
        self.central = central
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
        continuation: AsyncStream<BLEDevice>.Continuation
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
        onSuperseded: @escaping () -> Void,
        onConnect: @escaping (PeripheralRepresenting) -> Void,
        onFailToConnect: @escaping (PeripheralRepresenting, Error?) -> Void
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
}
