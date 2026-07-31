#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class PublicModelTests: XCTestCase {
    func testBLEDeviceStoresPeripheralIdentifierAndAdvertisementFields() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let service = CBUUID(string: "FFF0")
        let manufacturerData = Data([0x01, 0x02])

        let device = BLEDevice(
            id: id,
            name: "Arc Sensor",
            rssi: -42,
            advertisedServiceUUIDs: [service],
            manufacturerData: manufacturerData
        )

        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.name, "Arc Sensor")
        XCTAssertEqual(device.rssi, -42)
        XCTAssertEqual(device.advertisedServiceUUIDs, [service])
        XCTAssertEqual(device.manufacturerData, manufacturerData)
    }

    func testScanFilterDefaultsToNoRestrictions() {
        let filter = ScanFilter()

        XCTAssertEqual(filter.serviceUUIDs, [])
        XCTAssertEqual(filter.peripheralIdentifiers, [])
        XCTAssertNil(filter.name)
        XCTAssertNil(filter.namePrefix)
        XCTAssertNil(filter.manufacturerDataPrefix)
    }

    func testConnectionOptionsDefaults() {
        let options = ConnectionOptions()

        XCTAssertEqual(options.timeout, 10)
        XCTAssertEqual(options.autoReconnect, .disabled)
    }

    func testBLEErrorEquatableForIdentifierErrors() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        XCTAssertEqual(BLEError.deviceNotFound(id), BLEError.deviceNotFound(id))
        XCTAssertNotEqual(BLEError.scanTimedOut, BLEError.deviceNotFound(id))
    }
}
