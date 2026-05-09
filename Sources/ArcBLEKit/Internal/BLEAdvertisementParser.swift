#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

enum BLEAdvertisementParser {
    static func parse(_ advertisementData: [String: Any]) -> BLEAdvertisement {
        BLEAdvertisement(
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            serviceUUIDs: advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [],
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )
    }

    static func makeDevice(
        peripheral: PeripheralRepresenting,
        advertisement: BLEAdvertisement,
        rssi: Int
    ) -> BLEDevice {
        BLEDevice(
            id: peripheral.identifier,
            name: advertisement.localName ?? peripheral.name,
            rssi: rssi,
            advertisedServiceUUIDs: advertisement.serviceUUIDs,
            manufacturerData: advertisement.manufacturerData
        )
    }
}
