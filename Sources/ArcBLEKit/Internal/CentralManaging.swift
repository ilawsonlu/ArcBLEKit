#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

protocol CentralManaging: AnyObject, Sendable {
    var state: BluetoothState { get }
    var onStateChange: ((BluetoothState) -> Void)? { get set }
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)? { get set }
    var onConnect: ((PeripheralRepresenting) -> Void)? { get set }
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)? { get set }
    var onConnectionEvent: ((ConnectionEvent.Kind, PeripheralRepresenting) -> Void)? { get set }
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)? { get set }

    func scanForPeripherals(withServices services: [CBUUID]?)
    func registerForConnectionEvents(matching filter: ConnectionEventFilter?)
    func stopScan()
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting]
    func retrieveConnectedPeripherals(withServices services: [CBUUID]) -> [PeripheralRepresenting]
    func connect(_ peripheral: PeripheralRepresenting, options: ConnectionOptions)
    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting)
}
