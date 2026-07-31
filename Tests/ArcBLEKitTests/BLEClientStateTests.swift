import XCTest
@testable import ArcBLEKit

final class BLEClientStateTests: XCTestCase {
    func testBluetoothStatesEmitsCurrentStateAndSubsequentUpdates() async {
        let central = FakeCentralManager(state: .unknown)
        let client = BLEClient(central: central)
        var iterator = client.bluetoothStates.makeAsyncIterator()

        let initial = await iterator.next()
        central.updateState(.poweredOn)
        let updated = await iterator.next()

        XCTAssertEqual(initial, .unknown)
        XCTAssertEqual(updated, .poweredOn)
        XCTAssertEqual(client.bluetoothState, .poweredOn)
    }

    func testWaitUntilReadyReturnsAfterBluetoothPowersOn() async throws {
        let central = FakeCentralManager(state: .unknown)
        let client = BLEClient(central: central)
        let task = Task {
            try await client.waitUntilReady(timeout: 1)
        }

        await Task.yield()
        central.updateState(.poweredOn)

        try await task.value
    }

    func testWaitUntilReadyPreservesTerminalBluetoothError() async {
        let client = BLEClient(
            central: FakeCentralManager(state: .poweredOff)
        )

        do {
            try await client.waitUntilReady(timeout: 1)
            XCTFail("Expected bluetoothPoweredOff")
        } catch {
            XCTAssertEqual(error as? BLEError, .bluetoothPoweredOff)
        }
    }

    func testWaitUntilReadyTimesOut() async {
        let client = BLEClient(
            central: FakeCentralManager(state: .unknown)
        )

        do {
            try await client.waitUntilReady(timeout: 0.01)
            XCTFail("Expected bluetoothReadyTimedOut")
        } catch {
            XCTAssertEqual(error as? BLEError, .bluetoothReadyTimedOut)
        }
    }

    func testWaitUntilReadyMapsTaskCancellation() async {
        let client = BLEClient(
            central: FakeCentralManager(state: .unknown)
        )
        let task = Task {
            try await client.waitUntilReady(timeout: 1)
        }

        await Task.yield()
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected operationCancelled")
        } catch {
            XCTAssertEqual(error as? BLEError, .operationCancelled)
        }
    }
}
