#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

final class CentralManagerBox: NSObject, CentralManaging, @unchecked Sendable {
    private var manager: CBCentralManager!
    private var boxesByIdentifier: [UUID: PeripheralBox] = [:]

    var state: BluetoothState {
        BluetoothState(manager.state)
    }

    var onStateChange: ((BluetoothState) -> Void)?
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    var onConnect: ((PeripheralRepresenting) -> Void)?
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    init(configuration: BLEClient.Configuration) {
        var options: [String: Any]?
        if let restoreIdentifier = configuration.restoreIdentifier {
            options = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        }

        super.init()
        self.manager = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {
        manager.scanForPeripherals(withServices: services, options: nil)
    }

    func stopScan() {
        manager.stopScan()
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] {
        manager.retrievePeripherals(withIdentifiers: identifiers).map { box(for: $0) }
    }

    func connect(_ peripheral: PeripheralRepresenting) {
        guard let box = peripheral as? PeripheralBox else { return }
        manager.connect(box.peripheral, options: nil)
    }

    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting) {
        guard let box = peripheral as? PeripheralBox else { return }
        manager.cancelPeripheralConnection(box.peripheral)
    }

    private func box(for peripheral: CBPeripheral) -> PeripheralBox {
        if let existing = boxesByIdentifier[peripheral.identifier] {
            return existing
        }

        let box = PeripheralBox(peripheral: peripheral)
        boxesByIdentifier[peripheral.identifier] = box
        return box
    }
}

extension CentralManagerBox: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(BluetoothState(central.state))
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in peripherals {
            _ = box(for: peripheral)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        onDiscover?(
            box(for: peripheral),
            BLEAdvertisementParser.parse(advertisementData),
            RSSI.intValue
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onConnect?(box(for: peripheral))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onFailToConnect?(box(for: peripheral), error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        onDisconnect?(box(for: peripheral), error)
    }
}
