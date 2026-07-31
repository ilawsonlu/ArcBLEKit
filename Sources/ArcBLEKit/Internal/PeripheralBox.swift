#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

final class ServiceBox: ServiceRepresenting, @unchecked Sendable {
    let service: CBService
    var uuid: CBUUID { service.uuid }

    init(service: CBService) {
        self.service = service
    }
}

final class CharacteristicBox: CharacteristicRepresenting, @unchecked Sendable {
    let characteristic: CBCharacteristic
    var uuid: CBUUID { characteristic.uuid }
    var serviceUUID: CBUUID { characteristic.service?.uuid ?? CBUUID(string: "") }
    var properties: CBCharacteristicProperties { characteristic.properties }
    var isNotifying: Bool { characteristic.isNotifying }

    init(characteristic: CBCharacteristic) {
        self.characteristic = characteristic
    }
}

final class PeripheralBox: NSObject, PeripheralRepresenting, @unchecked Sendable {
    let peripheral: CBPeripheral

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }
    var onEvent: ((PeripheralEvent) -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        self.peripheral.delegate = self
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        peripheral.discoverServices(serviceUUIDs)
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {
        guard let serviceBox = service as? ServiceBox else { return }
        peripheral.discoverCharacteristics(characteristicUUIDs, for: serviceBox.service)
    }

    func readValue(for characteristic: CharacteristicRepresenting) {
        guard let characteristicBox = characteristic as? CharacteristicBox else { return }
        peripheral.readValue(for: characteristicBox.characteristic)
    }

    func writeValue(
        _ data: Data,
        for characteristic: CharacteristicRepresenting,
        type: CBCharacteristicWriteType
    ) {
        guard let characteristicBox = characteristic as? CharacteristicBox else { return }
        peripheral.writeValue(data, for: characteristicBox.characteristic, type: type)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {
        guard let characteristicBox = characteristic as? CharacteristicBox else { return }
        peripheral.setNotifyValue(enabled, for: characteristicBox.characteristic)
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        peripheral.maximumWriteValueLength(for: type)
    }
}

extension PeripheralBox: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services?.map(ServiceBox.init(service:)) ?? []
        onEvent?(.servicesDiscovered(services, error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let serviceBox = ServiceBox(service: service)
        let characteristics = service.characteristics?.map(CharacteristicBox.init(characteristic:)) ?? []
        onEvent?(.characteristicsDiscovered(serviceBox, characteristics, error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let box = CharacteristicBox(characteristic: characteristic)
        onEvent?(.valueUpdated(box, characteristic.value, error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        onEvent?(.valueWritten(CharacteristicBox(characteristic: characteristic), error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        onEvent?(
            .notificationStateUpdated(
                CharacteristicBox(characteristic: characteristic),
                error
            )
        )
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        onEvent?(.readyToWriteWithoutResponse)
    }
}
