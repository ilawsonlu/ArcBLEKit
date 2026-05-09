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
    private var peripheralsByIdentifier: [UUID: PeripheralRepresenting] = [:]

    public convenience init(configuration: Configuration = .init()) {
        self.init(central: CentralManagerBox(configuration: configuration))
    }

    init(central: CentralManaging) {
        self.central = central
    }

    func remember(_ peripheral: PeripheralRepresenting) {
        lock.lock()
        peripheralsByIdentifier[peripheral.identifier] = peripheral
        lock.unlock()
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
}
