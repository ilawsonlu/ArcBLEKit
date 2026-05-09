import CoreBluetooth
import Foundation
@testable import ArcBLEKit

final class FakeService: ServiceRepresenting {
    let uuid: CBUUID

    init(uuid: CBUUID) {
        self.uuid = uuid
    }
}

final class FakeCharacteristic: CharacteristicRepresenting {
    let uuid: CBUUID
    let serviceUUID: CBUUID

    init(uuid: CBUUID, serviceUUID: CBUUID) {
        self.uuid = uuid
        self.serviceUUID = serviceUUID
    }
}

final class FakePeripheral: PeripheralRepresenting {
    let identifier: UUID
    let name: String?

    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)?
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)?
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)?
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)?

    private(set) var discoveredServiceUUIDs: [CBUUID]?
    private(set) var discoveredCharacteristicUUIDs: [CBUUID]?
    private(set) var readCharacteristics: [CBUUID] = []
    private(set) var writtenValues: [(data: Data, characteristic: CBUUID, type: CBCharacteristicWriteType)] = []
    private(set) var notifyChanges: [(enabled: Bool, characteristic: CBUUID)] = []

    init(identifier: UUID = UUID(), name: String? = nil) {
        self.identifier = identifier
        self.name = name
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        discoveredServiceUUIDs = serviceUUIDs
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {
        discoveredCharacteristicUUIDs = characteristicUUIDs
    }

    func readValue(for characteristic: CharacteristicRepresenting) {
        readCharacteristics.append(characteristic.uuid)
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType) {
        writtenValues.append((data, characteristic.uuid, type))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {
        notifyChanges.append((enabled, characteristic.uuid))
    }

    func completeServiceDiscovery(_ services: [ServiceRepresenting], error: Error? = nil) {
        onServicesDiscovered?(services, error)
    }

    func completeCharacteristicDiscovery(
        service: ServiceRepresenting,
        characteristics: [CharacteristicRepresenting],
        error: Error? = nil
    ) {
        onCharacteristicsDiscovered?(service, characteristics, error)
    }

    func completeRead(characteristic: CharacteristicRepresenting, data: Data?, error: Error? = nil) {
        onValueRead?(characteristic, data, error)
    }

    func completeWrite(characteristic: CharacteristicRepresenting, error: Error? = nil) {
        onValueWritten?(characteristic, error)
    }

    func completeNotifySetup(characteristic: CharacteristicRepresenting, error: Error? = nil) {
        onNotificationStateUpdated?(characteristic, error)
    }

    func emitNotification(characteristic: CharacteristicRepresenting, data: Data) {
        onNotificationValue?(characteristic, data)
    }
}
