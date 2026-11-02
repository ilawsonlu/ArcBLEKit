#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation
@testable import ArcBLEKit

final class FakeCentralManager: CentralManaging, @unchecked Sendable {
    @TestLocked var state: BluetoothState
    @TestLocked var onStateChange: ((BluetoothState) -> Void)?
    @TestLocked var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    @TestLocked var onConnect: ((PeripheralRepresenting) -> Void)?
    @TestLocked var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    @TestLocked var onConnectionEvent: ((ConnectionEvent.Kind, PeripheralRepresenting) -> Void)?
    @TestLocked private(set) var registeredEventFilter: ConnectionEventFilter?
    @TestLocked private(set) var connectionEventRegistrationCount = 0
    @TestLocked var onRegisterConnectionEvents: ((ConnectionEventFilter?) -> Void)?
    @TestLocked var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    @TestLocked private(set) var scannedServiceUUIDs: [CBUUID]?
    @TestLocked private(set) var scanForPeripheralsCallCount = 0
    @TestLocked private(set) var didStopScan = false
    @TestLocked private(set) var stopScanCallCount = 0
    @TestLocked private(set) var retrievedIdentifiers: [UUID] = []
    @TestLocked private(set) var connectedIdentifiers: [UUID] = []
    @TestLocked private(set) var cancelledIdentifiers: [UUID] = []
    @TestLocked private(set) var connectionOptions: [ConnectionOptions] = []
    @TestLocked private(set) var connectedServiceQueries: [[CBUUID]] = []
    @TestLocked var systemConnectedPeripherals: [PeripheralRepresenting] = []
    @TestLocked var retrievedPeripherals: [PeripheralRepresenting] = []

    init(state: BluetoothState = .poweredOn) {
        self.state = state
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {
        scanForPeripheralsCallCount += 1
        scannedServiceUUIDs = services
        didStopScan = false
    }

    func registerForConnectionEvents(matching filter: ConnectionEventFilter?) {
        registeredEventFilter = filter
        connectionEventRegistrationCount += 1
        onRegisterConnectionEvents?(filter)
    }

    func stopScan() {
        didStopScan = true
        stopScanCallCount += 1
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] {
        retrievedIdentifiers = identifiers
        return retrievedPeripherals.filter { identifiers.contains($0.identifier) }
    }

    func retrieveConnectedPeripherals(withServices services: [CBUUID]) -> [PeripheralRepresenting] {
        connectedServiceQueries.append(services)
        return systemConnectedPeripherals
    }

    func connect(_ peripheral: PeripheralRepresenting, options: ConnectionOptions) {
        connectionOptions.append(options)
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
