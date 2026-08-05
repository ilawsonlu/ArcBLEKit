#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class PeripheralSessionOperationTests: XCTestCase {
    struct TestFailure: Error, CustomStringConvertible {
        var description: String { "operation failed" }
    }

    func testReadDiscoversServiceAndCharacteristicThenReturnsData() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.read(characteristic: characteristicUUID, service: serviceUUID)
        }

        await waitForServiceDiscovery(on: peripheral)
        XCTAssertEqual(peripheral.discoveredServiceUUIDs, [serviceUUID])
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        XCTAssertEqual(peripheral.discoveredCharacteristicUUIDs, [characteristicUUID])
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await waitForRead(on: peripheral)
        XCTAssertEqual(peripheral.readCharacteristics, [characteristicUUID])
        peripheral.completeRead(characteristic: characteristic, data: Data([0x01, 0x02]))

        let data = try await task.value
        XCTAssertEqual(data, Data([0x01, 0x02]))
    }

    func testWriteUsesDiscoveredCharacteristic() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF2")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.write(Data([0x09]), to: characteristicUUID, service: serviceUUID, type: .withResponse)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await waitForWrite(on: peripheral)
        XCTAssertEqual(peripheral.writtenValues.first?.data, Data([0x09]))
        XCTAssertEqual(peripheral.writtenValues.first?.characteristic, characteristicUUID)
        peripheral.completeWrite(characteristic: characteristic)

        try await task.value
    }

    func testNotificationsReturnStreamAndEmitValues() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let streamTask = Task {
            try await session.notifications(for: characteristicUUID, service: serviceUUID)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await waitForNotifyChange(on: peripheral)
        XCTAssertEqual(peripheral.notifyChanges.first?.enabled, true)
        peripheral.completeNotifySetup(characteristic: characteristic)

        let stream = try await streamTask.value
        var iterator = stream.makeAsyncIterator()
        peripheral.emitNotification(characteristic: characteristic, data: Data([0xAA]))

        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0xAA]))
    }

    func testMissingServiceThrowsServiceNotFound() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)

        let task = Task {
            try await session.read(characteristic: CBUUID(string: "FFF1"), service: serviceUUID)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([])

        do {
            _ = try await task.value
            XCTFail("Expected serviceNotFound")
        } catch {
            XCTAssertEqual(error as? BLEError, .serviceNotFound(serviceUUID))
        }
    }

    func testMissingCharacteristicThrowsCharacteristicNotFound() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)

        let task = Task {
            try await session.read(characteristic: characteristicUUID, service: serviceUUID)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [])

        do {
            _ = try await task.value
            XCTFail("Expected characteristicNotFound")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .characteristicNotFound(characteristicUUID, service: serviceUUID)
            )
        }
    }

    func testReadFailureThrowsReadFailed() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.read(characteristic: characteristicUUID, service: serviceUUID)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await waitForRead(on: peripheral)
        peripheral.completeRead(characteristic: characteristic, data: nil, error: TestFailure())

        do {
            _ = try await task.value
            XCTFail("Expected readFailed")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .readFailed(characteristicUUID, underlying: "operation failed")
            )
        }
    }

    func testWriteFailureThrowsWriteFailed() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF2")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.write(Data([0x09]), to: characteristicUUID, service: serviceUUID, type: .withResponse)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await waitForWrite(on: peripheral)
        peripheral.completeWrite(characteristic: characteristic, error: TestFailure())

        do {
            try await task.value
            XCTFail("Expected writeFailed")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .writeFailed(characteristicUUID, underlying: "operation failed")
            )
        }
    }

    func testNotificationSetupFailureThrowsNotificationSetupFailed() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.notifications(for: characteristicUUID, service: serviceUUID)
        }

        await waitForServiceDiscovery(on: peripheral)
        peripheral.completeServiceDiscovery([service])
        await waitForCharacteristicDiscovery(on: peripheral)
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await waitForNotifyChange(on: peripheral)
        peripheral.completeNotifySetup(characteristic: characteristic, error: TestFailure())

        do {
            _ = try await task.value
            XCTFail("Expected notificationSetupFailed")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .notificationSetupFailed(characteristicUUID, underlying: "operation failed")
            )
        }
    }

    func testNotificationsRejectCharacteristicWithoutNotifyOrIndicateByDefault() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        do {
            _ = try await session.notifications(
                for: characteristicUUID,
                service: serviceUUID
            )
            XCTFail("Expected unsupportedCharacteristicOperation")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .unsupportedCharacteristicOperation(
                    characteristicUUID,
                    operation: .notificationSetup
                )
            )
        }

        XCTAssertTrue(peripheral.notifyChanges.isEmpty)
    }

    func testNotificationsCanIgnoreUnsupportedPropertiesForCompatibility() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let task = Task {
            try await session.notifications(
                for: characteristicUUID,
                service: serviceUUID,
                allowUnsupportedProperties: true
            )
        }

        await waitForNotifyChange(on: peripheral)
        XCTAssertEqual(peripheral.notifyChanges.first?.enabled, true)
        peripheral.completeNotifySetup(characteristic: characteristic)

        _ = try await task.value
        await session.disconnect()
    }

    func testWriteWithoutResponseReturnsWithoutWaitingForWriteCallback() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF2")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.writeWithoutResponse]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        try await session.write(
            Data([0x01, 0x02]),
            to: characteristicUUID,
            service: serviceUUID,
            type: .withoutResponse
        )

        XCTAssertEqual(peripheral.writtenValues.count, 1)
        XCTAssertEqual(peripheral.writtenValues.first?.type, .withoutResponse)
    }

    func testWriteWithoutResponseWaitsForPeripheralBackpressureSignal() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF2")
        let peripheral = FakePeripheral()
        peripheral.canSendWriteWithoutResponse = false
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.writeWithoutResponse]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let task = Task {
            try await session.write(
                Data([0x03]),
                to: characteristicUUID,
                service: serviceUUID,
                type: .withoutResponse,
                options: GATTOperationOptions(timeout: 1)
            )
        }

        await assertNoWriteAfterYield(on: peripheral)
        peripheral.becomeReadyToWriteWithoutResponse()
        try await task.value

        XCTAssertEqual(peripheral.writtenValues.count, 1)
    }

    func testWriteRejectsPayloadLargerThanPeripheralMaximum() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF2")
        let peripheral = FakePeripheral()
        peripheral.maximumWriteLength = 2
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.write]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        do {
            try await session.write(
                Data([0x01, 0x02, 0x03]),
                to: characteristicUUID,
                service: serviceUUID,
                type: .withResponse
            )
            XCTFail("Expected valueTooLong")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .valueTooLong(actual: 3, maximum: 2)
            )
        }

        XCTAssertTrue(peripheral.writtenValues.isEmpty)
    }

    func testReadRejectsCharacteristicWithoutReadProperty() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.notify]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        do {
            _ = try await session.read(
                characteristic: characteristicUUID,
                service: serviceUUID
            )
            XCTFail("Expected unsupportedCharacteristicOperation")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .unsupportedCharacteristicOperation(
                    characteristicUUID,
                    operation: .read
                )
            )
        }
    }

    func testReadTimesOutWhenPeripheralDoesNotRespond() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        do {
            _ = try await session.read(
                characteristic: characteristicUUID,
                service: serviceUUID,
                options: GATTOperationOptions(timeout: 0.01)
            )
            XCTFail("Expected GATT timeout")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .gattOperationTimedOut(
                    .read,
                    service: serviceUUID,
                    characteristic: characteristicUUID
                )
            )
        }
    }

    func testCancellingReadReleasesQueueForNextOperation() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read, .write]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let readTask = Task {
            try await session.read(
                characteristic: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForRead(on: peripheral)
        readTask.cancel()

        do {
            _ = try await readTask.value
            XCTFail("Expected operationCancelled")
        } catch {
            XCTAssertEqual(error as? BLEError, .operationCancelled)
        }

        let writeTask = Task {
            try await session.write(
                Data([0x07]),
                to: characteristicUUID,
                service: serviceUUID,
                type: .withResponse
            )
        }
        await waitForWrite(on: peripheral)
        peripheral.completeWrite(characteristic: characteristic)
        try await writeTask.value
    }

    func testDisconnectFailsPendingRead() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let task = Task {
            try await session.read(
                characteristic: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForRead(on: peripheral)
        session.handleDisconnect(error: nil)

        do {
            _ = try await task.value
            XCTFail("Expected disconnected")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .disconnected(peripheral.identifier, underlying: nil)
            )
        }
    }

    func testNotificationUpdateAlsoCompletesPendingRead() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read, .notify]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let streamTask = Task {
            try await session.notifications(
                for: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForNotifyChange(on: peripheral)
        peripheral.completeNotifySetup(characteristic: characteristic)
        let stream = try await streamTask.value
        var iterator = stream.makeAsyncIterator()

        let readTask = Task {
            try await session.read(
                characteristic: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForRead(on: peripheral)
        peripheral.emitNotification(
            characteristic: characteristic,
            data: Data([0xA5])
        )

        let readValue = try await readTask.value
        let notificationValue = try await iterator.next()
        XCTAssertEqual(readValue, Data([0xA5]))
        XCTAssertEqual(notificationValue, Data([0xA5]))
    }

    func testReadFailureDoesNotFinishActiveNotificationStream() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.read, .notify]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let streamTask = Task {
            try await session.notifications(
                for: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForNotifyChange(on: peripheral)
        peripheral.completeNotifySetup(characteristic: characteristic)
        let stream = try await streamTask.value
        var iterator = stream.makeAsyncIterator()

        let readTask = Task {
            try await session.read(
                characteristic: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForRead(on: peripheral)
        peripheral.completeRead(
            characteristic: characteristic,
            data: nil,
            error: TestFailure()
        )

        do {
            _ = try await readTask.value
            XCTFail("Expected readFailed")
        } catch {
            XCTAssertEqual(
                error as? BLEError,
                .readFailed(
                    characteristicUUID,
                    underlying: "operation failed"
                )
            )
        }

        peripheral.emitNotification(
            characteristic: characteristic,
            data: Data([0xA6])
        )
        let notificationValue = try await iterator.next()
        XCTAssertEqual(notificationValue, Data([0xA6]))
    }

    func testNotificationStreamsUseServiceAndCharacteristicCompositeKey() async throws {
        let firstServiceUUID = CBUUID(string: "AAA0")
        let secondServiceUUID = CBUUID(string: "BBB0")
        let sharedCharacteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let firstCharacteristic = FakeCharacteristic(
            uuid: sharedCharacteristicUUID,
            serviceUUID: firstServiceUUID,
            properties: [.notify]
        )
        let secondCharacteristic = FakeCharacteristic(
            uuid: sharedCharacteristicUUID,
            serviceUUID: secondServiceUUID,
            properties: [.notify]
        )
        cache(firstCharacteristic, serviceUUID: firstServiceUUID, in: session)
        cache(secondCharacteristic, serviceUUID: secondServiceUUID, in: session)

        let firstStreamTask = Task {
            try await session.notifications(
                for: sharedCharacteristicUUID,
                service: firstServiceUUID
            )
        }
        await waitForNotifyChange(on: peripheral, count: 1)
        peripheral.completeNotifySetup(characteristic: firstCharacteristic)
        let firstStream = try await firstStreamTask.value
        var firstIterator = firstStream.makeAsyncIterator()

        let secondStreamTask = Task {
            try await session.notifications(
                for: sharedCharacteristicUUID,
                service: secondServiceUUID
            )
        }
        await waitForNotifyChange(on: peripheral, count: 2)
        peripheral.completeNotifySetup(characteristic: secondCharacteristic)
        let secondStream = try await secondStreamTask.value
        var secondIterator = secondStream.makeAsyncIterator()

        peripheral.emitNotification(
            characteristic: firstCharacteristic,
            data: Data([0x01])
        )
        peripheral.emitNotification(
            characteristic: secondCharacteristic,
            data: Data([0x02])
        )

        let firstValue = try await firstIterator.next()
        let secondValue = try await secondIterator.next()
        XCTAssertEqual(firstValue, Data([0x01]))
        XCTAssertEqual(secondValue, Data([0x02]))
    }

    func testSharedNotificationStopsAfterLastSubscriberCancels() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = makeSession(peripheral: peripheral)
        let characteristic = FakeCharacteristic(
            uuid: characteristicUUID,
            serviceUUID: serviceUUID,
            properties: [.notify]
        )
        cache(characteristic, serviceUUID: serviceUUID, in: session)

        let firstStreamTask = Task {
            try await session.notifications(
                for: characteristicUUID,
                service: serviceUUID
            )
        }
        await waitForNotifyChange(on: peripheral)
        peripheral.completeNotifySetup(characteristic: characteristic)
        let firstStream = try await firstStreamTask.value
        let secondStream = try await session.notifications(
            for: characteristicUUID,
            service: serviceUUID
        )

        XCTAssertEqual(peripheral.notifyChanges.count, 1)
        let firstConsumer = Task {
            for try await _ in firstStream {}
        }
        let secondConsumer = Task {
            for try await _ in secondStream {}
        }
        await Task.yield()

        firstConsumer.cancel()
        _ = try? await firstConsumer.value
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(peripheral.notifyChanges.count, 1)

        secondConsumer.cancel()
        _ = try? await secondConsumer.value
        await waitForNotifyChange(on: peripheral, count: 2)
        XCTAssertEqual(peripheral.notifyChanges.last?.enabled, false)
        peripheral.completeNotifySetup(characteristic: characteristic)
    }

    private func makeSession(peripheral: FakePeripheral) -> PeripheralSession {
        PeripheralSession(
            device: BLEDevice(
                id: peripheral.identifier,
                name: nil,
                rssi: 0,
                advertisedServiceUUIDs: [],
                manufacturerData: nil
            ),
            peripheral: peripheral,
            central: FakeCentralManager(),
            options: ConnectionOptions()
        )
    }

    private func cache(
        _ characteristic: FakeCharacteristic,
        serviceUUID: CBUUID,
        in session: PeripheralSession
    ) {
        session.characteristicCache.store(
            services: [FakeService(uuid: serviceUUID)]
        )
        session.characteristicCache.store(
            characteristics: [characteristic],
            serviceUUID: serviceUUID
        )
    }

    private func assertNoWriteAfterYield(on peripheral: FakePeripheral) async {
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertTrue(peripheral.writtenValues.isEmpty)
    }

    private func waitForServiceDiscovery(on peripheral: FakePeripheral) async {
        while peripheral.discoveredServiceUUIDs == nil {
            await Task.yield()
        }
    }

    private func waitForCharacteristicDiscovery(on peripheral: FakePeripheral) async {
        while peripheral.discoveredCharacteristicUUIDs == nil {
            await Task.yield()
        }
    }

    private func waitForRead(on peripheral: FakePeripheral) async {
        while peripheral.readCharacteristics.isEmpty {
            await Task.yield()
        }
    }

    private func waitForWrite(on peripheral: FakePeripheral) async {
        while peripheral.writtenValues.isEmpty {
            await Task.yield()
        }
    }

    private func waitForNotifyChange(
        on peripheral: FakePeripheral,
        count: Int = 1
    ) async {
        while peripheral.notifyChanges.count < count {
            await Task.yield()
        }
    }
}
