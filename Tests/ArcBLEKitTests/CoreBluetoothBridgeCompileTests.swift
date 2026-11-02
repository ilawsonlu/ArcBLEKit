import Foundation
import XCTest
@testable import ArcBLEKit

final class CoreBluetoothBridgeCompileTests: XCTestCase {
    func testOriginalReconnectFunctionReferenceRemainsAvailable() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)
        let reconnect: (UUID, ScanFilter?, ConnectionOptions) async throws -> PeripheralSession = client.reconnect

        let task = Task { try await reconnect(peripheral.identifier, nil, .init(timeout: 1)) }
        while central.connectedIdentifiers.isEmpty { await Task.yield() }
        central.completeConnection(peripheral)
        let session = try await task.value
        XCTAssertEqual(session.device.id, peripheral.identifier)
        await session.disconnect()
    }

    func testBLEClientCanBeCreatedWithPublicInitializer() {
        let client = BLEClient(configuration: .init(restoreIdentifier: "com.example.arc.ble"))

        XCTAssertNotNil(client)
    }
}
