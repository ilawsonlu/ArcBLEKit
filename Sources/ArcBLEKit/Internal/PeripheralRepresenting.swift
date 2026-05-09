#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

protocol ServiceRepresenting: AnyObject {
    var uuid: CBUUID { get }
}

protocol CharacteristicRepresenting: AnyObject {
    var uuid: CBUUID { get }
    var serviceUUID: CBUUID { get }
}

protocol PeripheralRepresenting: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)? { get set }
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)? { get set }
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)? { get set }
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)? { get set }
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)? { get set }
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)? { get set }

    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting)
    func readValue(for characteristic: CharacteristicRepresenting)
    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting)
}
