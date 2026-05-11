#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

final class ServiceBox: ServiceRepresenting {
    let service: CBService
    var uuid: CBUUID { service.uuid }

    init(service: CBService) {
        self.service = service
    }
}

final class CharacteristicBox: CharacteristicRepresenting {
    let characteristic: CBCharacteristic
    var uuid: CBUUID { characteristic.uuid }
    var serviceUUID: CBUUID { characteristic.service?.uuid ?? CBUUID(string: "") }

    init(characteristic: CBCharacteristic) {
        self.characteristic = characteristic
    }
}

final class PeripheralBox: NSObject, PeripheralRepresenting {
    let peripheral: CBPeripheral

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)?
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)?
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)?
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)?

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
}

extension PeripheralBox: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services?.map(ServiceBox.init(service:)) ?? []
        onServicesDiscovered?(services, error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let serviceBox = ServiceBox(service: service)
        let characteristics = service.characteristics?.map(CharacteristicBox.init(characteristic:)) ?? []
        onCharacteristicsDiscovered?(serviceBox, characteristics, error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let box = CharacteristicBox(characteristic: characteristic)
        if let error {
            onValueRead?(box, nil, error)
            return
        }

        if characteristic.isNotifying, let value = characteristic.value {
            onNotificationValue?(box, value)
        } else {
            onValueRead?(box, characteristic.value, nil)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        onValueWritten?(CharacteristicBox(characteristic: characteristic), error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        onNotificationStateUpdated?(CharacteristicBox(characteristic: characteristic), error)
    }
}
