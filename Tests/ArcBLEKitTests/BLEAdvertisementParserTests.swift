import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class BLEAdvertisementParserTests: XCTestCase {
    func testParsesLocalNameServiceUUIDsAndManufacturerData() {
        let service = CBUUID(string: "FFF0")
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "Arc Sensor",
            CBAdvertisementDataServiceUUIDsKey: [service],
            CBAdvertisementDataManufacturerDataKey: Data([0xAA, 0xBB])
        ]

        let advertisement = BLEAdvertisementParser.parse(advertisementData)

        XCTAssertEqual(advertisement.localName, "Arc Sensor")
        XCTAssertEqual(advertisement.serviceUUIDs, [service])
        XCTAssertEqual(advertisement.manufacturerData, Data([0xAA, 0xBB]))
    }

    func testBuildsBLEDeviceFromPeripheralAndAdvertisement() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Fallback Name")
        let advertisement = BLEAdvertisement(
            localName: "Advertisement Name",
            serviceUUIDs: [CBUUID(string: "FFF0")],
            manufacturerData: Data([0x10])
        )

        let device = BLEAdvertisementParser.makeDevice(
            peripheral: peripheral,
            advertisement: advertisement,
            rssi: -55
        )

        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.name, "Advertisement Name")
        XCTAssertEqual(device.rssi, -55)
        XCTAssertEqual(device.advertisedServiceUUIDs, [CBUUID(string: "FFF0")])
        XCTAssertEqual(device.manufacturerData, Data([0x10]))
    }

    func testBuildsBLEDeviceUsingPeripheralNameWhenAdvertisementNameIsMissing() {
        let peripheral = FakePeripheral(name: "Fallback Name")
        let advertisement = BLEAdvertisement(
            localName: nil,
            serviceUUIDs: [],
            manufacturerData: nil
        )

        let device = BLEAdvertisementParser.makeDevice(
            peripheral: peripheral,
            advertisement: advertisement,
            rssi: -60
        )

        XCTAssertEqual(device.name, "Fallback Name")
    }
}
