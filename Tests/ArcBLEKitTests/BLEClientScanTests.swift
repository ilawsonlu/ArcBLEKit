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

    func testScanPassesNilServicesToCentralWhenFilterHasNoServiceUUIDs() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)

        let stream = client.scan(filter: ScanFilter())
        _ = stream.makeAsyncIterator()

        XCTAssertNil(central.scannedServiceUUIDs)
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
        let rejectedByIdentifier = FakePeripheral(identifier: UUID(), name: "Arc One")
        let rejectedByNamePrefix = FakePeripheral(identifier: matchingID, name: "Other")
        let rejectedByManufacturerData = FakePeripheral(identifier: matchingID, name: "Arc Two")
        var iterator = client.scan(
            filter: ScanFilter(
                peripheralIdentifiers: [matchingID],
                namePrefix: "Arc",
                manufacturerDataPrefix: Data([0xAA])
            )
        ).makeAsyncIterator()

        central.discover(
            rejectedByIdentifier,
            advertisement: BLEAdvertisement(
                localName: "Arc One",
                serviceUUIDs: [],
                manufacturerData: Data([0xAA])
            ),
            rssi: -70
        )
        central.discover(
            rejectedByNamePrefix,
            advertisement: BLEAdvertisement(
                localName: "Other",
                serviceUUIDs: [],
                manufacturerData: Data([0xAA])
            ),
            rssi: -70
        )
        central.discover(
            rejectedByManufacturerData,
            advertisement: BLEAdvertisement(
                localName: "Arc Two",
                serviceUUIDs: [],
                manufacturerData: Data([0xBB])
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
        XCTAssertEqual(central.stopScanCallCount, 1)
    }

    func testStartingSecondScanFinishesFirstScanWithoutStoppingSecondScan() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        var firstIterator = client.scan(filter: ScanFilter(namePrefix: "First")).makeAsyncIterator()
        let firstNext = Task { await firstIterator.next() }

        let secondStream = client.scan(filter: ScanFilter(namePrefix: "Second"))
        var secondIterator = secondStream.makeAsyncIterator()
        let secondPeripheral = FakePeripheral(name: "Second Device")

        let firstResult = await firstNext.value
        XCTAssertNil(firstResult)
        XCTAssertFalse(central.didStopScan)
        XCTAssertEqual(central.stopScanCallCount, 0)

        central.discover(
            secondPeripheral,
            advertisement: BLEAdvertisement(
                localName: "Second Device",
                serviceUUIDs: [],
                manufacturerData: nil
            ),
            rssi: -50
        )

        let device = await secondIterator.next()
        XCTAssertEqual(device?.name, "Second Device")
    }

    func testScanDoesNotStartCentralScanWhenBluetoothIsPoweredOff() async {
        let central = FakeCentralManager(state: .poweredOff)
        let client = BLEClient(central: central)
        var iterator = client.scan(filter: ScanFilter()).makeAsyncIterator()

        let device = await iterator.next()

        XCTAssertNil(device)
        XCTAssertNil(central.scannedServiceUUIDs)
    }
}
