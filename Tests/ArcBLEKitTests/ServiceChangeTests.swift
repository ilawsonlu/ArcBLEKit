#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class ServiceChangeTests: XCTestCase {
    private let service = FakeService(uuid: CBUUID(string: "FFF0"))
    private let otherService = FakeService(uuid: CBUUID(string: "AAA0"))

    func testEventForReleasedServiceIsIgnoredWithoutCrashing() async throws {
        let (peripheral, session) = makeSession()
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        cache(characteristic, in: session)

        let readTask = Task {
            try await session.read(
                characteristic: characteristic.uuid, service: service.uuid, options: GATTOperationOptions(timeout: 2)
            )
        }
        try await waitUntil { peripheral.readCharacteristics.count == 1 }

        let orphan = FakeCharacteristic(uuid: characteristic.uuid, serviceUUID: service.uuid)
        orphan.serviceUUID = nil
        peripheral.completeRead(characteristic: orphan, data: Data([0x01]))
        peripheral.completeWrite(characteristic: orphan)
        peripheral.completeNotifySetup(characteristic: orphan)

        peripheral.completeRead(characteristic: characteristic, data: Data([0x02]))
        let value = try await readTask.value
        XCTAssertEqual(value, Data([0x02]))
    }

    func testServiceChangeResubscribesAffectedNotificationStream() async throws {
        let (peripheral, session) = makeSession()
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        let stream = try await subscribe(characteristic, in: session, peripheral: peripheral)
        var iterator = stream.makeAsyncIterator()

        peripheral.modifyServices([service])

        let replacementService = FakeService(uuid: service.uuid)
        let replacement = FakeCharacteristic(uuid: characteristic.uuid, serviceUUID: service.uuid)
        try await waitUntil { peripheral.serviceDiscoveryRequests.count == 2 }
        XCTAssertEqual(peripheral.serviceDiscoveryRequests.last, [service.uuid])
        peripheral.completeServiceDiscovery([replacementService])
        try await waitUntil { peripheral.characteristicDiscoveryRequests.count == 2 }
        peripheral.completeCharacteristicDiscovery(service: replacementService, characteristics: [replacement])
        try await waitUntil { peripheral.notifyChanges.count == 2 }
        XCTAssertTrue(peripheral.notifyCharacteristics.last === replacement)
        XCTAssertEqual(peripheral.notifyChanges.last?.enabled, true)
        peripheral.completeNotifySetup(characteristic: replacement)

        peripheral.emitNotification(characteristic: replacement, data: Data([0x42]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x42]))
        XCTAssertTrue(session.isConnected)
    }

    func testRemovedServiceFinishesOnlyAffectedStream() async throws {
        let (peripheral, session) = makeSession()
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        let otherCharacteristic = FakeCharacteristic(uuid: CBUUID(string: "AAA1"), serviceUUID: otherService.uuid)
        let stream = try await subscribe(characteristic, in: session, peripheral: peripheral)
        let otherStream = try await subscribe(
            otherCharacteristic, service: otherService, in: session, peripheral: peripheral
        )
        let discoveriesBefore = peripheral.serviceDiscoveryRequests.count

        peripheral.modifyServices([service])
        try await waitUntil { peripheral.serviceDiscoveryRequests.count == discoveriesBefore + 1 }
        peripheral.completeServiceDiscovery([otherService])

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected the affected stream to fail")
        } catch {
            XCTAssertEqual(error as? BLEError, .serviceNotFound(service.uuid))
        }

        var otherIterator = otherStream.makeAsyncIterator()
        peripheral.emitNotification(characteristic: otherCharacteristic, data: Data([0x07]))
        let otherValue = try await otherIterator.next()
        XCTAssertEqual(otherValue, Data([0x07]))
        XCTAssertTrue(session.isConnected)
    }

    func testServiceChangeOnlyDropsInvalidatedCacheEntries() async throws {
        let (_, session) = makeSession()
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        let otherCharacteristic = FakeCharacteristic(uuid: CBUUID(string: "AAA1"), serviceUUID: otherService.uuid)
        cache(characteristic, in: session)
        cache(otherCharacteristic, service: otherService, in: session)

        session.handlePeripheralEvent(.servicesModified([service]))

        XCTAssertNil(session.characteristicCache.service(for: service.uuid))
        XCTAssertNil(session.characteristicCache.characteristic(characteristic.uuid, service: service.uuid))
        XCTAssertTrue(session.characteristicCache.service(for: otherService.uuid) === otherService)
        XCTAssertTrue(
            session.characteristicCache.characteristic(otherCharacteristic.uuid, service: otherService.uuid)
                === otherCharacteristic
        )
    }

    // MARK: - Helpers

    private func makeSession() -> (FakePeripheral, PeripheralSession) {
        let peripheral = FakePeripheral()
        let session = PeripheralSession(
            device: BLEDevice(
                id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil
            ),
            peripheral: peripheral,
            central: FakeCentralManager(),
            options: ConnectionOptions(timeout: 1)
        )
        addTeardownBlock { await session.disconnect() }
        return (peripheral, session)
    }

    private func cache(
        _ characteristic: FakeCharacteristic,
        service: FakeService? = nil,
        in session: PeripheralSession
    ) {
        let service = service ?? self.service
        session.characteristicCache.store(services: [service])
        session.characteristicCache.store(characteristics: [characteristic], serviceUUID: service.uuid)
    }

    private func subscribe(
        _ characteristic: FakeCharacteristic,
        service: FakeService? = nil,
        in session: PeripheralSession,
        peripheral: FakePeripheral
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let service = service ?? self.service
        let services = peripheral.serviceDiscoveryRequests.count
        let characteristics = peripheral.characteristicDiscoveryRequests.count
        let notifications = peripheral.notifyChanges.count
        let task = Task {
            try await session.notifications(
                for: characteristic.uuid, service: service.uuid, options: GATTOperationOptions(timeout: 2)
            )
        }
        try await waitUntil { peripheral.serviceDiscoveryRequests.count == services + 1 }
        peripheral.completeServiceDiscovery([service])
        try await waitUntil { peripheral.characteristicDiscoveryRequests.count == characteristics + 1 }
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        try await waitUntil { peripheral.notifyChanges.count == notifications + 1 }
        peripheral.completeNotifySetup(characteristic: characteristic)
        return try await task.value
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
