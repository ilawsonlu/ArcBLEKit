#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class ReconnectRestorationRetryTests: XCTestCase {
    private let service = FakeService(uuid: CBUUID(string: "FFF0"))

    func testDisconnectDuringRestorationUsesNextAttempt() async throws {
        let fixture = try await makeSubscribedFixture(maxAttempts: 2)
        var iterator = fixture.stream.makeAsyncIterator()

        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 2 }
        fixture.central.completeConnection(fixture.peripheral)
        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == 2 }

        // The link drops again while notifications are being restored.
        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 3 }
        fixture.central.completeConnection(fixture.peripheral)

        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == 3 }
        fixture.peripheral.completeServiceDiscovery([service])
        // The interrupted attempt never got past service discovery.
        try await waitUntil { fixture.peripheral.characteristicDiscoveryRequests.count == 2 }
        fixture.peripheral.completeCharacteristicDiscovery(service: service, characteristics: [fixture.characteristic])
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic)

        // Restoration reports `.ready` after rediscovery and again once the reconnect completes,
        // so wait for both before comparing (initial state + 2 = 3).
        try await waitUntil { fixture.states.values.filter { $0 == .ready }.count == 3 }
        XCTAssertEqual(fixture.states.values, [
            .ready, .disconnected,
            .reconnecting(attempt: 1), .connecting, .connected, .discoveringServices,
            .reconnecting(attempt: 2), .connecting, .connected, .discoveringServices, .ready, .ready
        ])

        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x5A]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x5A]))
        XCTAssertTrue(fixture.session.isConnected)
    }

    func testDisconnectDuringRestorationOnLastAttemptFailsSession() async throws {
        let fixture = try await makeSubscribedFixture(maxAttempts: 1)

        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 2 }
        fixture.central.completeConnection(fixture.peripheral)
        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == 2 }

        fixture.central.disconnect(fixture.peripheral)

        try await waitUntil { fixture.states.finished }
        guard case .failed(.disconnected(fixture.peripheral.identifier, _))? = fixture.states.values.last else {
            return XCTFail("Expected disconnected failure, got \(fixture.states.values)")
        }
        XCTAssertEqual(fixture.central.connectedIdentifiers.count, 2)
    }

    // MARK: - Helpers

    private struct Fixture {
        let central: FakeCentralManager
        let peripheral: FakePeripheral
        let characteristic: FakeCharacteristic
        let session: PeripheralSession
        let stream: AsyncThrowingStream<Data, Error>
        let states: StateRecorder
    }

    private final class StateRecorder: @unchecked Sendable {
        @TestLocked var values: [ConnectionState] = []
        @TestLocked var finished = false
    }

    private func makeSubscribedFixture(maxAttempts: Int) async throws -> Fixture {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        let client = BLEClient(central: central)
        client.remember(peripheral)
        let device = BLEDevice(
            id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil
        )
        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(timeout: 2, autoReconnect: .limited(maxAttempts: maxAttempts, delay: 0))
            )
        }
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        central.completeConnection(peripheral)
        let session = try await connectTask.value

        let streamTask = Task {
            try await session.notifications(for: characteristic.uuid, service: service.uuid)
        }
        try await waitUntil { peripheral.serviceDiscoveryRequests.count == 1 }
        peripheral.completeServiceDiscovery([service])
        try await waitUntil { peripheral.characteristicDiscoveryRequests.count == 1 }
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        try await waitUntil { peripheral.notifyChanges.count == 1 }
        peripheral.completeNotifySetup(characteristic: characteristic)
        let stream = try await streamTask.value

        let states = StateRecorder()
        let stateTask = Task {
            for await state in session.connectionStates {
                states.values.append(state)
            }
            states.finished = true
        }
        try await waitUntil { states.values == [.ready] }
        addTeardownBlock {
            await session.disconnect()
            stateTask.cancel()
            _ = client
        }
        return Fixture(
            central: central,
            peripheral: peripheral,
            characteristic: characteristic,
            session: session,
            stream: stream,
            states: states
        )
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
