#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

enum PeripheralEvent: @unchecked Sendable {
    case servicesDiscovered([ServiceRepresenting], Error?)
    case characteristicsDiscovered(
        ServiceRepresenting,
        [CharacteristicRepresenting],
        Error?
    )
    case valueUpdated(CharacteristicRepresenting, Data?, Error?)
    case valueWritten(CharacteristicRepresenting, Error?)
    case notificationStateUpdated(CharacteristicRepresenting, Error?)
    case readyToWriteWithoutResponse
}

protocol ServiceRepresenting: AnyObject, Sendable {
    var uuid: CBUUID { get }
}

protocol CharacteristicRepresenting: AnyObject, Sendable {
    var uuid: CBUUID { get }
    var serviceUUID: CBUUID { get }
    var properties: CBCharacteristicProperties { get }
    var isNotifying: Bool { get }
}

protocol PeripheralRepresenting: AnyObject, Sendable {
    var identifier: UUID { get }
    var name: String? { get }
    var canSendWriteWithoutResponse: Bool { get }
    var onEvent: ((PeripheralEvent) -> Void)? { get set }

    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting)
    func readValue(for characteristic: CharacteristicRepresenting)
    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
}
