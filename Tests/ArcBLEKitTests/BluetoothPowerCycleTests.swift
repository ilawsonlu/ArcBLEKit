#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class BluetoothPowerCycleTests: XCTestCase {
    func testPowerOffFinishesActiveScanWithError() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let result = TestLocked<Result<Int, Error>?>(wrappedValue: nil)

        let task = Task {
            var count = 0
            do {
                for try await _ in client.scan(filter: ScanFilter()) { count += 1 }
                result.wrappedValue = .success(count)
            } catch {
                result.wrappedValue = .failure(error)
            }
        }
        defer { task.cancel() }

        try await waitUntil { central.scanForPeripheralsCallCount == 1 }
        central.updateState(.poweredOff)
        try await waitUntil { result.wrappedValue != nil }

        guard case let .failure(error) = result.wrappedValue else {
            return XCTFail("Expected scan to fail")
        }
        XCTAssertEqual(error as? BLEError, .bluetoothPoweredOff)
        XCTAssertNil(central.onDiscover)
    }

    func testPowerOffFailsFindDeviceBeforeTimeout() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)

        let task = Task {
            try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: 30)
        }
        try await waitUntil { central.scanForPeripheralsCallCount == 1 }
        central.updateState(.resetting)

        let outcome = try await boundedResult(of: task)
        XCTAssertEqual(outcome.failure as? BLEError, .bluetoothUnavailable)
    }

    func testPowerOffFailsPendingConnectionBeforeTimeout() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(
                identifier: peripheral.identifier,
                fallbackScan: nil,
                options: ConnectionOptions(timeout: 30)
            )
        }
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        central.updateState(.poweredOff)

        let outcome = try await boundedResult(of: task)
        XCTAssertEqual(outcome.failure as? BLEError, .bluetoothPoweredOff)
        XCTAssertNil(central.onConnect)
        XCTAssertNil(central.onFailToConnect)
    }

    func testPowerOffEndsSessionWithoutAutoReconnect() async throws {
        let (central, peripheral, session) = try await connectedSession(options: ConnectionOptions(timeout: 1))
        let states = try await record(session)

        let service = FakeService(uuid: CBUUID(string: "FFF0"))
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        session.characteristicCache.store(services: [service])
        session.characteristicCache.store(characteristics: [characteristic], serviceUUID: service.uuid)
        let readTask = Task {
            try await session.read(
                characteristic: characteristic.uuid,
                service: service.uuid,
                options: GATTOperationOptions(timeout: 30)
            )
        }
        try await waitUntil { peripheral.readCharacteristics.count == 1 }

        central.updateState(.poweredOff)

        let readOutcome = try await boundedResult(of: readTask)
        guard case .disconnected(peripheral.identifier, _)? = readOutcome.failure as? BLEError else {
            return XCTFail("Expected disconnected, got \(String(describing: readOutcome.failure))")
        }
        try await waitUntil { states.finished }
        XCTAssertEqual(states.values, [.ready, .disconnected])
        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(session.connectionState, .disconnected)
    }

    func testAutoReconnectWaitsForBluetoothThenReconnects() async throws {
        let (central, peripheral, session) = try await connectedSession(
            options: ConnectionOptions(timeout: 5, autoReconnect: .limited(maxAttempts: 1, delay: 0))
        )
        central.retrievedPeripherals = [peripheral]
        let states = try await record(session)

        central.updateState(.poweredOff)
        try await waitUntil { states.values.last == .connecting }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(central.connectedIdentifiers.count, 1, "Must not connect while Bluetooth is off")
        XCTAssertFalse(session.isConnected)

        central.updateState(.poweredOn)
        try await waitUntil { central.connectedIdentifiers.count == 2 }
        XCTAssertEqual(central.retrievedIdentifiers, [peripheral.identifier])
        central.completeConnection(peripheral)

        try await waitUntil { states.values.last == .ready }
        XCTAssertEqual(
            states.values,
            [.ready, .disconnected, .reconnecting(attempt: 1), .connecting, .connected, .ready]
        )
        XCTAssertTrue(session.isConnected)
        await session.disconnect()
    }

    func testUnauthorizedDuringReconnectFailsSession() async throws {
        let (central, _, session) = try await connectedSession(
            options: ConnectionOptions(timeout: 5, autoReconnect: .limited(maxAttempts: 1, delay: 0))
        )
        let states = try await record(session)

        central.updateState(.poweredOff)
        try await waitUntil { states.values.last == .connecting }
        central.updateState(.unauthorized)

        try await waitUntil { states.finished }
        XCTAssertEqual(states.values.last, .failed(.bluetoothUnauthorized))
    }

    // MARK: - Connection state streams

    func testConnectionStatesSupportConcurrentSubscribers() async throws {
        let (central, peripheral, session) = try await connectedSession(options: ConnectionOptions(timeout: 1))
        let first = try await record(session)
        let second = try await record(session)
        try await waitUntil { first.values == [.ready] && second.values == [.ready] }

        central.disconnect(peripheral)

        try await waitUntil { first.finished && second.finished }
        XCTAssertEqual(first.values, [.ready, .disconnected])
        XCTAssertEqual(second.values, [.ready, .disconnected])
    }

    func testLateSubscriberReceivesCurrentStateAndFinishedSessionFinishesImmediately() async throws {
        let (_, _, session) = try await connectedSession(options: ConnectionOptions(timeout: 1))
        XCTAssertEqual(session.connectionState, .ready)

        var iterator = session.connectionStates.makeAsyncIterator()
        let current = await iterator.next()
        XCTAssertEqual(current, .ready)

        await session.disconnect()
        let afterDisconnect = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(afterDisconnect, .disconnected)
        XCTAssertNil(end)

        var lateIterator = session.connectionStates.makeAsyncIterator()
        let finalState = await lateIterator.next()
        let lateEnd = await lateIterator.next()
        XCTAssertEqual(finalState, .disconnected)
        XCTAssertNil(lateEnd)
    }

    // MARK: - Helpers

    private final class StateRecorder: @unchecked Sendable {
        @TestLocked var values: [ConnectionState] = []
        @TestLocked var finished = false
        var task: Task<Void, Never>?
    }

    /// Returns once the subscriber has received the session's current state, so later
    /// transitions cannot race ahead of the subscription.
    private func record(_ session: PeripheralSession) async throws -> StateRecorder {
        let recorder = StateRecorder()
        recorder.task = Task {
            for await state in session.connectionStates {
                recorder.values.append(state)
            }
            recorder.finished = true
        }
        addTeardownBlock { recorder.task?.cancel() }
        try await waitUntil { !recorder.values.isEmpty }
        return recorder
    }

    private func connectedSession(
        options: ConnectionOptions
    ) async throws -> (FakeCentralManager, FakePeripheral, PeripheralSession) {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        client.remember(peripheral)
        let device = BLEDevice(
            id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil
        )
        let task = Task { try await client.connect(to: device, options: options) }
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        central.completeConnection(peripheral)
        let session = try await task.value
        addTeardownBlock {
            await session.disconnect()
            _ = client
        }
        return (central, peripheral, session)
    }

    private func boundedResult<T>(
        of task: Task<T, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Result<T, Error> {
        let result = TestLocked<Result<T, Error>?>(wrappedValue: nil)
        let waiter = Task {
            do {
                result.wrappedValue = .success(try await task.value)
            } catch {
                result.wrappedValue = .failure(error)
            }
        }
        defer { waiter.cancel() }
        do {
            try await waitUntil(file: file, line: line) { result.wrappedValue != nil }
        } catch {
            task.cancel()
            throw error
        }
        return result.wrappedValue!
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
