import Foundation

public final class BLEClient {
    public struct Configuration: Sendable {
        public var restoreIdentifier: String?

        public init(restoreIdentifier: String? = nil) {
            self.restoreIdentifier = restoreIdentifier
        }
    }

    let central: CentralManaging
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var peripheralsByIdentifier: [UUID: PeripheralRepresenting] = [:]
    private var activeScanID: UUID?
    private var activeScanContinuation: AsyncStream<BLEDevice>.Continuation?

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

    func endScan(id: UUID) -> Bool {
        scanLock.lock()
        defer { scanLock.unlock() }

        guard activeScanID == id else {
            return false
        }

        activeScanID = nil
        activeScanContinuation = nil
        return true
    }
}
