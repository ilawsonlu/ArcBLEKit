import CoreBluetooth
import Foundation
@testable import ArcBLEKit

final class FakeCentralManager: CentralManaging {
    var state: BluetoothState
    var onStateChange: ((BluetoothState) -> Void)?
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    var onConnect: ((PeripheralRepresenting) -> Void)?
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    private(set) var scannedServiceUUIDs: [CBUUID]?
    private(set) var didStopScan = false
    private(set) var retrievedIdentifiers: [UUID] = []
    private(set) var connectedIdentifiers: [UUID] = []
    private(set) var cancelledIdentifiers: [UUID] = []
    var retrievedPeripherals: [PeripheralRepresenting] = []

    init(state: BluetoothState = .poweredOn) {
        self.state = state
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {
        scannedServiceUUIDs = services
        didStopScan = false
    }

    func stopScan() {
        didStopScan = true
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] {
        retrievedIdentifiers = identifiers
        return retrievedPeripherals
    }

    func connect(_ peripheral: PeripheralRepresenting) {
        connectedIdentifiers.append(peripheral.identifier)
    }

    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting) {
        cancelledIdentifiers.append(peripheral.identifier)
    }

    func updateState(_ state: BluetoothState) {
        self.state = state
        onStateChange?(state)
    }

    func discover(
        _ peripheral: PeripheralRepresenting,
        advertisement: BLEAdvertisement,
        rssi: Int
    ) {
        onDiscover?(peripheral, advertisement, rssi)
    }

    func completeConnection(_ peripheral: PeripheralRepresenting) {
        onConnect?(peripheral)
    }

    func failConnection(_ peripheral: PeripheralRepresenting, error: Error? = nil) {
        onFailToConnect?(peripheral, error)
    }

    func disconnect(_ peripheral: PeripheralRepresenting, error: Error? = nil) {
        onDisconnect?(peripheral, error)
    }
}
