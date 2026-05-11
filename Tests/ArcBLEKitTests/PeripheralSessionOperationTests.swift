import CoreBluetooth
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

        let value = await iterator.next()
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

    private func waitForNotifyChange(on peripheral: FakePeripheral) async {
        while peripheral.notifyChanges.isEmpty {
            await Task.yield()
        }
    }
}
