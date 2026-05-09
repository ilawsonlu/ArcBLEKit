#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

final class CentralManagerBox: NSObject, CentralManaging {
    var state: BluetoothState { .poweredOff }
    var onStateChange: ((BluetoothState) -> Void)?
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    var onConnect: ((PeripheralRepresenting) -> Void)?
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    init(configuration: BLEClient.Configuration) {
        super.init()
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {}
    func stopScan() {}
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] { [] }
    func connect(_ peripheral: PeripheralRepresenting) {}
    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting) {}
}
