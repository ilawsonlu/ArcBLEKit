#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

final class PeripheralBox: NSObject, PeripheralRepresenting {
    var identifier: UUID { UUID() }
    var name: String? { nil }
    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)?
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)?
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)?
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)?

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {}
    func readValue(for characteristic: CharacteristicRepresenting) {}
    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType) {}
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {}
}
