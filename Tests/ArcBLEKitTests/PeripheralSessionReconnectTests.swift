import XCTest
@testable import ArcBLEKit

final class PeripheralSessionReconnectTests: XCTestCase {
    func testUnexpectedDisconnectEmitsDisconnectedState() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = BLEDevice(
            id: peripheral.identifier,
            name: nil,
            rssi: 0,
            advertisedServiceUUIDs: [],
            manufacturerData: nil
        )
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(to: device, options: ConnectionOptions(timeout: 1))
        }

        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        var iterator = session.connectionStates.makeAsyncIterator()

        _ = await iterator.next()
        central.disconnect(peripheral)

        let state = await iterator.next()
        XCTAssertEqual(state, .disconnected)
    }

    func testLimitedAutoReconnectEmitsReconnectStateAndReconnectsOnce() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = BLEDevice(
            id: peripheral.identifier,
            name: nil,
            rssi: 0,
            advertisedServiceUUIDs: [],
            manufacturerData: nil
        )
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(
                    timeout: 1,
                    autoReconnect: .limited(maxAttempts: 1, delay: 0.01)
                )
            )
        }

        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        var iterator = session.connectionStates.makeAsyncIterator()

        _ = await iterator.next()
        central.disconnect(peripheral)
        let disconnected = await iterator.next()
        let reconnecting = await iterator.next()

        XCTAssertEqual(disconnected, .disconnected)
        XCTAssertEqual(reconnecting, .reconnecting(attempt: 1))
        await waitForConnectAttempt(on: central, count: 2)
        XCTAssertEqual(
            central.connectedIdentifiers.filter { $0 == peripheral.identifier }.count,
            2
        )
    }

    private func waitForConnectAttempt(on central: FakeCentralManager, count: Int = 1) async {
        while central.connectedIdentifiers.count < count {
            await Task.yield()
        }
    }
}
