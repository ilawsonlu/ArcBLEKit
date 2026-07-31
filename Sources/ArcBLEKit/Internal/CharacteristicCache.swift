#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

final class CharacteristicCache {
    private let lock = NSLock()
    private var servicesByUUID: [CBUUID: ServiceRepresenting] = [:]
    private var characteristicsByServiceAndUUID: [String: CharacteristicRepresenting] = [:]

    func service(for uuid: CBUUID) -> ServiceRepresenting? {
        lock.lock()
        defer { lock.unlock() }
        return servicesByUUID[uuid]
    }

    func store(services: [ServiceRepresenting]) {
        lock.lock()
        defer { lock.unlock() }
        for service in services {
            servicesByUUID[service.uuid] = service
        }
    }

    func characteristic(
        _ characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) -> CharacteristicRepresenting? {
        lock.lock()
        defer { lock.unlock() }
        return characteristicsByServiceAndUUID[
            key(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)
        ]
    }

    func store(characteristics: [CharacteristicRepresenting], serviceUUID: CBUUID) {
        lock.lock()
        defer { lock.unlock() }
        for characteristic in characteristics {
            characteristicsByServiceAndUUID[
                key(serviceUUID: serviceUUID, characteristicUUID: characteristic.uuid)
            ] = characteristic
        }
    }

    func clear() {
        lock.lock()
        servicesByUUID.removeAll()
        characteristicsByServiceAndUUID.removeAll()
        lock.unlock()
    }

    private func key(serviceUUID: CBUUID, characteristicUUID: CBUUID) -> String {
        "\(serviceUUID.uuidString)::\(characteristicUUID.uuidString)"
    }
}
