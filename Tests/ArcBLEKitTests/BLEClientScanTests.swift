import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class BLEClientScanTests: XCTestCase {
    func testScanPassesServiceUUIDsToCentral() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let service = CBUUID(string: "FFF0")

        let stream = client.scan(filter: ScanFilter(serviceUUIDs: [service]))
        _ = stream.makeAsyncIterator()

        XCTAssertEqual(central.scannedServiceUUIDs, [service])
    }

    func testScanEmitsMatchingDeviceAndStoresPeripheralForLaterConnection() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc Peripheral")
        let service = CBUUID(string: "FFF0")
        var iterator = client.scan(filter: ScanFilter(serviceUUIDs: [service])).makeAsyncIterator()

        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(
                localName: "Arc Sensor",
                serviceUUIDs: [service],
                manufacturerData: Data([0x01])
            ),
            rssi: -45
        )

        let device = await iterator.next()
        XCTAssertEqual(device?.id, id)
        XCTAssertEqual(device?.name, "Arc Sensor")
        XCTAssertEqual(device?.rssi, -45)
        XCTAssertEqual(device?.advertisedServiceUUIDs, [service])
        XCTAssertTrue(client.rememberedPeripheral(identifier: id) === peripheral)
    }

    func testScanFiltersByPeripheralIdentifierNamePrefixAndManufacturerData() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let matchingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let matchingPeripheral = FakePeripheral(identifier: matchingID, name: "Arc One")
        let rejectedPeripheral = FakePeripheral(identifier: UUID(), name: "Other")
        var iterator = client.scan(
            filter: ScanFilter(
                peripheralIdentifiers: [matchingID],
                namePrefix: "Arc",
                manufacturerDataPrefix: Data([0xAA])
            )
        ).makeAsyncIterator()

        central.discover(
            rejectedPeripheral,
            advertisement: BLEAdvertisement(
                localName: "Other",
                serviceUUIDs: [],
                manufacturerData: Data([0xAA])
            ),
            rssi: -70
        )
        central.discover(
            matchingPeripheral,
            advertisement: BLEAdvertisement(
                localName: "Arc One",
                serviceUUIDs: [],
                manufacturerData: Data([0xAA, 0x01])
            ),
            rssi: -40
        )

        let device = await iterator.next()
        XCTAssertEqual(device?.id, matchingID)
    }

    func testCancellingScanIteratorStopsCentralScan() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        var stream: AsyncStream<BLEDevice>? = client.scan(filter: ScanFilter())
        _ = stream?.makeAsyncIterator()

        stream = nil
        await Task.yield()

        XCTAssertTrue(central.didStopScan)
    }
}
