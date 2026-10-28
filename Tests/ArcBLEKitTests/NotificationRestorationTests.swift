#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class NotificationRestorationTests: XCTestCase {
    private struct Fixture {
        let central: FakeCentralManager
        let peripheral: FakePeripheral
        let client: BLEClient
        let session: PeripheralSession
        let states: TestLocked<[ConnectionState]>
        let service = FakeService(uuid: CBUUID(string: "FFF0"))
        let characteristic: FakeCharacteristic
    }

    private let setupError = NSError(domain: CBATTErrorDomain, code: 6)

    func testCompatibilityRestoresOriginalStreamsAfterRejectedSetup() async throws {
        let fixture = try await makeFixture(properties: [.read])
        let first = try await subscribe(fixture, compatible: true, setupError: setupError)
        let second = try await fixture.session.notifications(
            for: fixture.characteristic.uuid,
            service: fixture.service.uuid,
            allowUnsupportedProperties: true
        )
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 1)

        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        fixture.peripheral.completeNotifySetup(
            characteristic: fixture.characteristic,
            error: setupError
        )
        try await assertRestored(fixture)

        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x42]))
        let firstValue = try await firstIterator.next()
        let secondValue = try await secondIterator.next()
        XCTAssertEqual(firstValue, Data([0x42]))
        XCTAssertEqual(secondValue, Data([0x42]))
        XCTAssertEqual(fixture.central.connectedIdentifiers.count, 2)
        await fixture.session.disconnect()
    }

    func testRestorePreservesUnfilteredDiscovery() async throws {
        let fixture = try await makeFixture()
        let task = Task {
            try await fixture.session.notifications(
                for: fixture.characteristic.uuid,
                service: fixture.service.uuid,
                discoveryMode: .all
            )
        }
        try await completeDiscovery(fixture, count: 1, mode: .all)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 1 }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic)
        let stream = try await task.value
        var iterator = stream.makeAsyncIterator()

        try await reconnectAndDiscover(fixture, discoveryCount: 2, mode: .all)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic)
        try await assertRestored(fixture)
        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x43]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x43]))
        await fixture.session.disconnect()
    }

    func testStrictSubscriberCannotJoinChannelWithUnconfirmedSetup() async throws {
        let fixture = try await makeFixture()
        let compatible = try await subscribe(fixture, compatible: true, setupError: setupError)
        var iterator = compatible.makeAsyncIterator()
        let strict = Task {
            try await fixture.session.notifications(
                for: fixture.characteristic.uuid,
                service: fixture.service.uuid
            )
        }
        // The operation is serialized; awaiting it must not silently accept the existing channel.
        let outcome = TestLocked(wrappedValue: false)
        let observer = Task {
            _ = await strict.result
            outcome.wrappedValue = true
        }
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 || outcome.wrappedValue }
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 2)
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic, error: setupError)
        switch await strict.result {
        case .success: XCTFail("Strict subscriber accepted an unconfirmed notification channel")
        case let .failure(error):
            XCTAssertEqual(error as? BLEError, .notificationSetupFailed(
                fixture.characteristic.uuid, underlying: String(describing: setupError)
            ))
        }
        await observer.value
        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x44]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x44]))
        await fixture.session.disconnect()
    }

    func testStrictRestorationValidatesRediscoveredProperties() async throws {
        let fixture = try await makeFixture()
        let stream = try await subscribe(fixture)
        var iterator = stream.makeAsyncIterator()
        let changed = FakeCharacteristic(
            uuid: fixture.characteristic.uuid,
            serviceUUID: fixture.service.uuid,
            properties: [.read]
        )
        try await reconnectAndDiscover(fixture, characteristic: changed)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 || !fixture.session.isConnected }
        // Complete unexpected setup too, so the regression fails without hanging on old code.
        if fixture.peripheral.notifyChanges.count == 2 {
            fixture.peripheral.completeNotifySetup(characteristic: changed)
        }
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 1)
        try await waitUntil { !fixture.session.isConnected }
        do {
            _ = try await iterator.next()
            XCTFail("Expected strict property validation to finish the original stream")
        } catch {
            XCTAssertEqual(error as? BLEError, .unsupportedCharacteristicOperation(
                changed.uuid, operation: .notificationSetup
            ))
        }
    }

    func testStrictSubscriberRevalidatesMissingPropertiesWithoutRemovingCompatibleStream() async throws {
        let fixture = try await makeFixture(properties: [.read])
        let stream = try await subscribe(fixture, compatible: true, setupError: setupError)
        do {
            _ = try await fixture.session.notifications(for: fixture.characteristic.uuid, service: fixture.service.uuid)
            XCTFail("Expected strict property validation")
        } catch {
            XCTAssertEqual(error as? BLEError, .unsupportedCharacteristicOperation(
                fixture.characteristic.uuid, operation: .notificationSetup
            ))
        }
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 1)
        var iterator = stream.makeAsyncIterator()
        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x45]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x45]))
    }

    func testStrictSubscriberCanConfirmCompatibilityChannelAndKeepsRestorationStrict() async throws {
        let fixture = try await makeFixture()
        let compatible = try await subscribe(fixture, compatible: true, setupError: setupError)
        let strict = try await subscribe(fixture)
        let third = try await fixture.session.notifications(
            for: fixture.characteristic.uuid, service: fixture.service.uuid
        )
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 2)
        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 3 }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic, error: setupError)
        let expected = BLEError.notificationSetupFailed(
            fixture.characteristic.uuid, underlying: String(describing: setupError)
        )
        try await assertFailed(fixture, stream: compatible, error: expected)
        try await assertFailed(fixture, stream: strict, error: expected)
        try await assertFailed(fixture, stream: third, error: expected)
        XCTAssertEqual(fixture.central.connectedIdentifiers.count, 2)
    }

    func testCancellingStrictSubscriberRecomputesCompatibilityForRestoration() async throws {
        let fixture = try await makeFixture()
        let compatible = try await subscribe(fixture, compatible: true)
        let strict = try await fixture.session.notifications(
            for: fixture.characteristic.uuid, service: fixture.service.uuid
        )
        let consumer = Task { for try await _ in strict {} }
        consumer.cancel()
        _ = try? await consumer.value
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 1)

        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic, error: setupError)
        try await assertRestored(fixture)
        var iterator = compatible.makeAsyncIterator()
        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x46]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x46]))
    }

    func testSharedDiscoveryUsesAllRegardlessOfSubscriberOrder() async throws {
        for allFirst in [true, false] {
            let fixture = try await makeFixture()
            let first = try await subscribe(fixture, mode: allFirst ? .all : .targeted)
            let secondTask = Task {
                try await fixture.session.notifications(
                    for: fixture.characteristic.uuid, service: fixture.service.uuid,
                    discoveryMode: allFirst ? .targeted : .all
                )
            }
            if !allFirst { try await completeDiscovery(fixture, count: 1, mode: .all) }
            let second = try await secondTask.value
            XCTAssertEqual(fixture.peripheral.notifyChanges.count, 1)
            try await reconnectAndDiscover(fixture, discoveryCount: 2, mode: .all)
            try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
            fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic)
            try await assertRestored(fixture)
            var firstIterator = first.makeAsyncIterator()
            var secondIterator = second.makeAsyncIterator()
            fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x47]))
            let firstValue = try await firstIterator.next()
            let secondValue = try await secondIterator.next()
            XCTAssertEqual(firstValue, Data([0x47]))
            XCTAssertEqual(secondValue, Data([0x47]))
            await fixture.session.disconnect()
        }
    }

    func testCancellingAllConsumersDuringDiscoveryDoesNotEnableNotifications() async throws {
        let fixture = try await makeFixture()
        let stream = try await subscribe(fixture, compatible: true)
        let consumer = Task { for try await _ in stream {} }
        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 2 }
        fixture.central.completeConnection(fixture.peripheral)
        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == 1 }

        consumer.cancel()
        _ = try? await consumer.value
        XCTAssertTrue(fixture.session.notificationRegistry.activeIDs().isEmpty)
        fixture.peripheral.completeServiceDiscovery([fixture.service])
        try await waitUntil { fixture.peripheral.characteristicDiscoveryRequests.count == 1 }
        fixture.peripheral.completeCharacteristicDiscovery(service: fixture.service, characteristics: [fixture.characteristic])
        try await assertRestored(fixture)
        XCTAssertEqual(fixture.peripheral.notifyChanges.count, 1)
        XCTAssertTrue(fixture.session.notificationRegistry.activeIDs().isEmpty)
    }

    func testCancellingDuringSetupDisablesRediscoveredCharacteristic() async throws {
        let fixture = try await makeFixture()
        let stream = try await subscribe(fixture)
        let consumer = Task { for try await _ in stream {} }
        let replacement = FakeCharacteristic(uuid: fixture.characteristic.uuid, serviceUUID: fixture.service.uuid)
        try await reconnectAndDiscover(fixture, characteristic: replacement)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        consumer.cancel()
        _ = try? await consumer.value
        fixture.peripheral.completeNotifySetup(characteristic: replacement)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 3 }
        XCTAssertEqual(fixture.peripheral.notifyChanges.last?.enabled, false)
        XCTAssertTrue(fixture.peripheral.notifyCharacteristics.last === replacement)
        fixture.peripheral.completeNotifySetup(characteristic: replacement)
        try await assertRestored(fixture)
        XCTAssertTrue(fixture.session.notificationRegistry.activeIDs().isEmpty)
    }

    func testCancellingStrictConsumerDuringSetupReevaluatesRestorationPolicy() async throws {
        let fixture = try await makeFixture()
        let compatible = try await subscribe(fixture, compatible: true)
        let strict = try await fixture.session.notifications(
            for: fixture.characteristic.uuid, service: fixture.service.uuid
        )
        let consumer = Task { for try await _ in strict {} }
        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        consumer.cancel()
        _ = try? await consumer.value
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic, error: setupError)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 3 }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic, error: setupError)
        try await assertRestored(fixture)
        var iterator = compatible.makeAsyncIterator()
        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([0x48]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x48]))
    }

    func testRestorationKeepsSameCharacteristicUUIDInDifferentServicesSeparate() async throws {
        let fixture = try await makeFixture(properties: [.read])
        let compatible = try await subscribe(fixture, compatible: true, setupError: setupError)
        let otherService = FakeService(uuid: CBUUID(string: "AAA0"))
        let otherCharacteristic = FakeCharacteristic(
            uuid: fixture.characteristic.uuid, serviceUUID: otherService.uuid, properties: [.notify]
        )
        fixture.session.characteristicCache.store(services: [otherService])
        fixture.session.characteristicCache.store(characteristics: [otherCharacteristic], serviceUUID: otherService.uuid)
        let strictTask = Task {
            try await fixture.session.notifications(for: otherCharacteristic.uuid, service: otherService.uuid)
        }
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        fixture.peripheral.completeNotifySetup(characteristic: otherCharacteristic)
        let strict = try await strictTask.value

        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 2 }
        fixture.central.completeConnection(fixture.peripheral)
        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == 1 }
        fixture.peripheral.completeServiceDiscovery([fixture.service, otherService])
        for count in 1...2 {
            try await waitUntil { fixture.peripheral.characteristicDiscoveryRequests.count == count }
            let serviceUUID = try XCTUnwrap(fixture.peripheral.characteristicDiscoveryRequests.last?.service)
            let isCompatible = serviceUUID == fixture.service.uuid
            let service = isCompatible ? fixture.service : otherService
            let characteristic = isCompatible ? fixture.characteristic : otherCharacteristic
            fixture.peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
            try await waitUntil { fixture.peripheral.notifyChanges.count == count + 2 }
            fixture.peripheral.completeNotifySetup(characteristic: characteristic, error: isCompatible ? setupError : nil)
        }
        try await assertRestored(fixture)
        var compatibleIterator = compatible.makeAsyncIterator()
        var strictIterator = strict.makeAsyncIterator()
        fixture.peripheral.emitNotification(characteristic: fixture.characteristic, data: Data([1]))
        fixture.peripheral.emitNotification(characteristic: otherCharacteristic, data: Data([2]))
        let compatibleValue = try await compatibleIterator.next()
        let strictValue = try await strictIterator.next()
        XCTAssertEqual(compatibleValue, Data([1]))
        XCTAssertEqual(strictValue, Data([2]))
        XCTAssertEqual(fixture.central.connectedIdentifiers.count, 2)
    }

    func testCompatibilityDoesNotHideRestorationDiscoveryFailure() async throws {
        let fixture = try await makeFixture()
        let stream = try await subscribe(fixture, compatible: true)
        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 2 }
        fixture.central.completeConnection(fixture.peripheral)
        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == 1 }
        fixture.peripheral.completeServiceDiscovery([], error: setupError)
        try await assertFailed(fixture, stream: stream, error: .serviceNotFound(fixture.service.uuid))
    }

    func testCompatibilityRestorationUsesSessionTimeout() async throws {
        let fixture = try await makeFixture(timeout: 0.1)
        let stream = try await subscribe(fixture, compatible: true)
        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        // The original subscription used the default 10 seconds, not the session's 0.1 seconds.
        try await assertFailed(fixture, stream: stream, error: .gattOperationTimedOut(
            .notificationSetup, service: fixture.service.uuid, characteristic: fixture.characteristic.uuid
        ))
    }

    func testCompatibilityDoesNotHideDisconnectDuringRestoration() async throws {
        let fixture = try await makeFixture()
        let stream = try await subscribe(fixture, compatible: true)
        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        fixture.central.disconnect(fixture.peripheral)
        try await assertFailed(fixture, stream: stream, error: .disconnected(fixture.peripheral.identifier, underlying: nil))
    }

    func testManualDisconnectDuringRestorationCancelsOriginalStream() async throws {
        let fixture = try await makeFixture()
        let stream = try await subscribe(fixture, compatible: true)
        try await reconnectAndDiscover(fixture)
        try await waitUntil { fixture.peripheral.notifyChanges.count == 2 }
        await fixture.session.disconnect()
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual(error as? BLEError, .operationCancelled) }
        XCTAssertEqual(fixture.central.connectedIdentifiers.count, 2)
        XCTAssertTrue(fixture.session.notificationRegistry.activeIDs().isEmpty)
    }

    func testCompatibilityDoesNotHideInitialSetupCancellationOrTimeout() async throws {
        for cancel in [true, false] {
            let fixture = try await makeFixture()
            let task = Task {
                try await fixture.session.notifications(
                    for: fixture.characteristic.uuid, service: fixture.service.uuid,
                    options: GATTOperationOptions(timeout: 0.1), allowUnsupportedProperties: true
                )
            }
            try await waitUntil { fixture.peripheral.notifyChanges.count == 1 }
            if cancel { task.cancel() }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation or timeout")
            } catch {
                XCTAssertEqual(error as? BLEError, cancel ? .operationCancelled : .gattOperationTimedOut(
                    .notificationSetup, service: fixture.service.uuid, characteristic: fixture.characteristic.uuid
                ))
            }
            XCTAssertTrue(fixture.session.notificationRegistry.activeIDs().isEmpty)
            await fixture.session.disconnect()
        }
    }

    private func makeFixture(
        properties: CBCharacteristicProperties = [.notify],
        timeout: TimeInterval = 1
    ) async throws -> Fixture {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        client.remember(peripheral)
        let device = BLEDevice(
            id: peripheral.identifier, name: nil, rssi: 0,
            advertisedServiceUUIDs: [], manufacturerData: nil
        )
        let task = Task {
            try await client.connect(to: device, options: ConnectionOptions(
                timeout: timeout, autoReconnect: .limited(maxAttempts: 1, delay: 0)
            ))
        }
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        central.completeConnection(peripheral)
        let session = try await task.value
        let states = TestLocked(wrappedValue: [ConnectionState]())
        let stateTask = Task {
            for await state in session.connectionStates {
                states.wrappedValue.append(state)
            }
        }
        addTeardownBlock {
            await session.disconnect()
            await stateTask.value
        }
        let fixture = Fixture(
            central: central, peripheral: peripheral, client: client, session: session, states: states,
            characteristic: FakeCharacteristic(
                uuid: CBUUID(string: "FFF3"), serviceUUID: CBUUID(string: "FFF0"),
                properties: properties
            )
        )
        session.characteristicCache.store(services: [fixture.service])
        session.characteristicCache.store(characteristics: [fixture.characteristic], serviceUUID: fixture.service.uuid)
        return fixture
    }

    private func subscribe(
        _ fixture: Fixture, compatible: Bool = false, setupError: Error? = nil,
        mode: GATTDiscoveryMode = .targeted
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let count = fixture.peripheral.notifyChanges.count + 1
        let discoveryCount = fixture.peripheral.serviceDiscoveryRequests.count + 1
        let task = Task {
            try await fixture.session.notifications(
                for: fixture.characteristic.uuid, service: fixture.service.uuid,
                allowUnsupportedProperties: compatible, discoveryMode: mode
            )
        }
        if mode == .all {
            try await completeDiscovery(fixture, count: discoveryCount, mode: mode)
        }
        try await waitUntil { fixture.peripheral.notifyChanges.count == count }
        fixture.peripheral.completeNotifySetup(characteristic: fixture.characteristic, error: setupError)
        return try await task.value
    }

    private func reconnectAndDiscover(
        _ fixture: Fixture, discoveryCount: Int = 1,
        mode: GATTDiscoveryMode = .targeted, characteristic: FakeCharacteristic? = nil
    ) async throws {
        fixture.central.disconnect(fixture.peripheral)
        try await waitUntil { fixture.central.connectedIdentifiers.count == 2 }
        fixture.central.completeConnection(fixture.peripheral)
        try await completeDiscovery(fixture, count: discoveryCount, mode: mode, characteristic: characteristic)
    }

    private func completeDiscovery(
        _ fixture: Fixture, count: Int, mode: GATTDiscoveryMode,
        characteristic: FakeCharacteristic? = nil
    ) async throws {
        try await waitUntil { fixture.peripheral.serviceDiscoveryRequests.count == count }
        XCTAssertEqual(fixture.peripheral.serviceDiscoveryRequests.last!, mode == .all ? nil : [fixture.service.uuid])
        fixture.peripheral.completeServiceDiscovery([fixture.service])
        try await waitUntil { fixture.peripheral.characteristicDiscoveryRequests.count == count }
        XCTAssertEqual(fixture.peripheral.characteristicDiscoveryRequests.last?.characteristics,
                       mode == .all ? nil : [fixture.characteristic.uuid])
        fixture.peripheral.completeCharacteristicDiscovery(
            service: fixture.service, characteristics: [characteristic ?? fixture.characteristic]
        )
    }

    private func assertRestored(_ fixture: Fixture) async throws {
        // A queued GATT operation completes only after restoration leaves the session queue.
        _ = try await fixture.session.operationQueue.run { true }
        try await waitUntil {
            fixture.states.wrappedValue.filter { $0 == .ready }.count >= 3 || !fixture.session.isConnected
        }
        XCTAssertTrue(fixture.session.isConnected)
        XCTAssertFalse(fixture.states.wrappedValue.contains { if case .failed = $0 { return true }; return false })
        try fixture.session.ensureConnected()
    }

    private func assertFailed(_ fixture: Fixture, stream: AsyncThrowingStream<Data, Error>, error: BLEError) async throws {
        try await waitUntil { fixture.states.wrappedValue.contains(.failed(error)) }
        XCTAssertFalse(fixture.session.isConnected)
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected restoration error")
        } catch let actual { XCTAssertEqual(actual as? BLEError, error) }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for BLE operation", file: file, line: line)
                throw BLEError.operationCancelled
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
