#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class PeripheralSessionReconnectTests: XCTestCase {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

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

        let connected = await iterator.next()
        let ready = await iterator.next()
        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(ready, .ready)
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

        let connected = await iterator.next()
        let ready = await iterator.next()
        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(ready, .ready)
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

        let connecting = await iterator.next()
        central.completeConnection(peripheral)
        let reconnected = await iterator.next()
        let readyAfterReconnect = await iterator.next()

        XCTAssertEqual(connecting, .connecting)
        XCTAssertEqual(reconnected, .connected)
        XCTAssertEqual(readyAfterReconnect, .ready)
        await session.disconnect()
    }

    func testManualDisconnectDoesNotStartAutoReconnect() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = makeDevice(for: peripheral)
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(
                    timeout: 1,
                    autoReconnect: .limited(maxAttempts: 2, delay: 0)
                )
            )
        }
        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)
        let session = try await connectTask.value

        await session.disconnect()
        central.disconnect(peripheral)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(central.connectedIdentifiers.count, 1)
        XCTAssertEqual(central.cancelledIdentifiers, [peripheral.identifier])
    }

    func testAutoReconnectRetriesAfterFailureAndThenBecomesReady() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = makeDevice(for: peripheral)
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(
                    timeout: 1,
                    autoReconnect: .limited(maxAttempts: 2, delay: 0)
                )
            )
        }
        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        var iterator = session.connectionStates.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        central.disconnect(peripheral)
        await assertNext(&iterator, equals: .disconnected)
        await assertNext(&iterator, equals: .reconnecting(attempt: 1))
        await assertNext(&iterator, equals: .connecting)
        await waitForConnectAttempt(on: central, count: 2)
        central.failConnection(
            peripheral,
            error: TestFailure(description: "first retry failed")
        )

        await assertNext(&iterator, equals: .reconnecting(attempt: 2))
        await assertNext(&iterator, equals: .connecting)
        await waitForConnectAttempt(on: central, count: 3)
        central.completeConnection(peripheral)

        await assertNext(&iterator, equals: .connected)
        await assertNext(&iterator, equals: .ready)
        XCTAssertEqual(central.connectedIdentifiers.count, 3)
        await session.disconnect()
    }

    func testAutoReconnectEmitsFailureAfterExhaustingAttempts() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = makeDevice(for: peripheral)
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(
                    timeout: 1,
                    autoReconnect: .limited(maxAttempts: 2, delay: 0)
                )
            )
        }
        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        var iterator = session.connectionStates.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        central.disconnect(peripheral)
        await assertNext(&iterator, equals: .disconnected)

        for attempt in 1...2 {
            await assertNext(
                &iterator,
                equals: .reconnecting(attempt: attempt)
            )
            await assertNext(&iterator, equals: .connecting)
            await waitForConnectAttempt(on: central, count: attempt + 1)
            central.failConnection(
                peripheral,
                error: TestFailure(description: "retry \(attempt) failed")
            )
        }

        let expectedError = BLEError.connectionFailed(
            peripheral.identifier,
            underlying: "retry 2 failed"
        )
        await assertNext(&iterator, equals: .failed(expectedError))
        await assertNext(&iterator, equals: nil)
        XCTAssertEqual(central.connectedIdentifiers.count, 3)
    }

    func testAutoReconnectRestoresActiveNotificationStream() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = makeDevice(for: peripheral)
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.notify]
        )
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(
                    timeout: 1,
                    autoReconnect: .limited(maxAttempts: 1, delay: 0)
                )
            )
        }
        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        session.characteristicCache.store(services: [service])
        session.characteristicCache.store(
            characteristics: [characteristic],
            serviceUUID: serviceUUID
        )

        let streamTask = Task {
            try await session.notifications(
                for: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForNotificationChange(on: peripheral, count: 1)
        peripheral.completeNotifySetup(characteristic: characteristic)
        let stream = try await streamTask.value
        var notificationIterator = stream.makeAsyncIterator()
        var stateIterator = session.connectionStates.makeAsyncIterator()
        _ = await stateIterator.next()
        _ = await stateIterator.next()

        central.disconnect(peripheral)
        await assertNext(&stateIterator, equals: .disconnected)
        await assertNext(&stateIterator, equals: .reconnecting(attempt: 1))
        await assertNext(&stateIterator, equals: .connecting)
        await waitForConnectAttempt(on: central, count: 2)
        central.completeConnection(peripheral)
        await assertNext(&stateIterator, equals: .connected)
        await assertNext(&stateIterator, equals: .discoveringServices)

        await waitForServiceDiscovery(on: peripheral, count: 1)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral, count: 1)
        peripheral.completeCharacteristicDiscovery(
            service: service,
            characteristics: [characteristic]
        )
        await waitForNotificationChange(on: peripheral, count: 2)
        peripheral.completeNotifySetup(characteristic: characteristic)
        await assertNext(&stateIterator, equals: .ready)

        peripheral.emitNotification(
            characteristic: characteristic,
            data: Data([0x44])
        )
        let value = try await notificationIterator.next()
        XCTAssertEqual(value, Data([0x44]))
        await session.disconnect()
    }

    private func makeDevice(for peripheral: FakePeripheral) -> BLEDevice {
        BLEDevice(
            id: peripheral.identifier,
            name: peripheral.name,
            rssi: 0,
            advertisedServiceUUIDs: [],
            manufacturerData: nil
        )
    }

    private func assertNext(
        _ iterator: inout AsyncStream<ConnectionState>.Iterator,
        equals expected: ConnectionState?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = await iterator.next()
        XCTAssertEqual(state, expected, file: file, line: line)
    }

    private func waitForServiceDiscovery(
        on peripheral: FakePeripheral,
        count: Int
    ) async {
        while peripheral.serviceDiscoveryRequests.count < count {
            await Task.yield()
        }
    }

    private func waitForCharacteristicDiscovery(
        on peripheral: FakePeripheral,
        count: Int
    ) async {
        while peripheral.characteristicDiscoveryRequests.count < count {
            await Task.yield()
        }
    }

    private func waitForNotificationChange(
        on peripheral: FakePeripheral,
        count: Int
    ) async {
        while peripheral.notifyChanges.count < count {
            await Task.yield()
        }
    }

    private func waitForConnectAttempt(on central: FakeCentralManager, count: Int = 1) async {
        while central.connectedIdentifiers.count < count {
            await Task.yield()
        }
    }
}
