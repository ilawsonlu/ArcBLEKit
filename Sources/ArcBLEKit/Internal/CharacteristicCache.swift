#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif

final class CharacteristicCache {
    private var servicesByUUID: [CBUUID: ServiceRepresenting] = [:]
    private var characteristicsByServiceAndUUID: [String: CharacteristicRepresenting] = [:]

    func service(for uuid: CBUUID) -> ServiceRepresenting? {
        servicesByUUID[uuid]
    }

    func store(services: [ServiceRepresenting]) {
        for service in services {
            servicesByUUID[service.uuid] = service
        }
    }

    func characteristic(
        _ characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) -> CharacteristicRepresenting? {
        characteristicsByServiceAndUUID[key(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)]
    }

    func store(characteristics: [CharacteristicRepresenting], serviceUUID: CBUUID) {
        for characteristic in characteristics {
            characteristicsByServiceAndUUID[
                key(serviceUUID: serviceUUID, characteristicUUID: characteristic.uuid)
            ] = characteristic
        }
    }

    private func key(serviceUUID: CBUUID, characteristicUUID: CBUUID) -> String {
        "\(serviceUUID.uuidString)::\(characteristicUUID.uuidString)"
    }
}
