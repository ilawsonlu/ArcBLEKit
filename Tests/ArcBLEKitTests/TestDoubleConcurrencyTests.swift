import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class TestDoubleConcurrencyTests: XCTestCase {
    func testConcurrentRecordingAndSnapshotReadsPreserveAllAttempts() {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: CBUUID(string: "FFF0"))

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            central.connect(peripheral, options: .init())
            peripheral.writeValue(Data([0x01]), for: characteristic, type: .withResponse)
            _ = central.connectedIdentifiers.count
            _ = peripheral.writtenValues.last
        }

        XCTAssertEqual(central.connectedIdentifiers.count, 200)
        XCTAssertEqual(central.connectionOptions.count, 200)
        XCTAssertEqual(peripheral.writtenValues.count, 200)
    }
}
