#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation
@testable import ArcBLEKit

final class FakeService: ServiceRepresenting, @unchecked Sendable {
    let uuid: CBUUID

    init(uuid: CBUUID) {
        self.uuid = uuid
    }
}

final class FakeCharacteristic: CharacteristicRepresenting, @unchecked Sendable {
    let uuid: CBUUID
    let serviceUUID: CBUUID
    let properties: CBCharacteristicProperties
    @TestLocked var isNotifying: Bool

    init(
        uuid: CBUUID,
        serviceUUID: CBUUID,
        properties: CBCharacteristicProperties = [
            .read,
            .write,
            .writeWithoutResponse,
            .notify
        ],
        isNotifying: Bool = false
    ) {
        self.uuid = uuid
        self.serviceUUID = serviceUUID
        self.properties = properties
        self.isNotifying = isNotifying
    }
}

final class FakePeripheral: PeripheralRepresenting, @unchecked Sendable {
    let identifier: UUID
    let name: String?

    @TestLocked private var writeWithoutResponseReady = true
    @TestLocked var onCanSendWriteWithoutResponseRead: ((Bool) -> Void)?
    var canSendWriteWithoutResponse: Bool {
        get {
            let isReady = writeWithoutResponseReady
            onCanSendWriteWithoutResponseRead?(isReady)
            return isReady
        }
        set {
            writeWithoutResponseReady = newValue
        }
    }
    @TestLocked var maximumWriteLength = 512
    @TestLocked var onEvent: ((PeripheralEvent) -> Void)?

    @TestLocked private(set) var discoveredServiceUUIDs: [CBUUID]?
    @TestLocked private(set) var discoveredCharacteristicUUIDs: [CBUUID]?
    @TestLocked private(set) var discoveredCharacteristicsForServiceUUID: CBUUID?
    @TestLocked private(set) var serviceDiscoveryRequests: [[CBUUID]?] = []
    @TestLocked private(set) var characteristicDiscoveryRequests: [
        (characteristics: [CBUUID]?, service: CBUUID)
    ] = []
    @TestLocked private(set) var readCharacteristics: [CBUUID] = []
    @TestLocked private(set) var writtenValues: [(data: Data, characteristic: CBUUID, type: CBCharacteristicWriteType)] = []
    @TestLocked private(set) var notifyChanges: [(enabled: Bool, characteristic: CBUUID)] = []
    @TestLocked private(set) var notifyCharacteristics: [CharacteristicRepresenting] = []

    init(identifier: UUID = UUID(), name: String? = nil) {
        self.identifier = identifier
        self.name = name
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        discoveredServiceUUIDs = serviceUUIDs
        serviceDiscoveryRequests.append(serviceUUIDs)
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {
        discoveredCharacteristicUUIDs = characteristicUUIDs
        discoveredCharacteristicsForServiceUUID = service.uuid
        characteristicDiscoveryRequests.append(
            (characteristicUUIDs, service.uuid)
        )
    }

    func readValue(for characteristic: CharacteristicRepresenting) {
        readCharacteristics.append(characteristic.uuid)
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType) {
        writtenValues.append((data, characteristic.uuid, type))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {
        notifyCharacteristics.append(characteristic)
        notifyChanges.append((enabled, characteristic.uuid))
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        maximumWriteLength
    }

    func completeServiceDiscovery(_ services: [ServiceRepresenting], error: Error? = nil) {
        onEvent?(.servicesDiscovered(services, error))
    }

    func completeCharacteristicDiscovery(
        service: ServiceRepresenting,
        characteristics: [CharacteristicRepresenting],
        error: Error? = nil
    ) {
        onEvent?(.characteristicsDiscovered(service, characteristics, error))
    }

    func completeRead(characteristic: CharacteristicRepresenting, data: Data?, error: Error? = nil) {
        onEvent?(.valueUpdated(characteristic, data, error))
    }

    func completeWrite(characteristic: CharacteristicRepresenting, error: Error? = nil) {
        onEvent?(.valueWritten(characteristic, error))
    }

    func completeNotifySetup(characteristic: CharacteristicRepresenting, error: Error? = nil) {
        if error == nil, let characteristic = characteristic as? FakeCharacteristic {
            characteristic.isNotifying = notifyChanges.last?.enabled ?? false
        }
        onEvent?(.notificationStateUpdated(characteristic, error))
    }

    func emitNotification(characteristic: CharacteristicRepresenting, data: Data) {
        onEvent?(.valueUpdated(characteristic, data, nil))
    }

    func becomeReadyToWriteWithoutResponse() {
        canSendWriteWithoutResponse = true
        onEvent?(.readyToWriteWithoutResponse)
    }
}
