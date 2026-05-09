import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class BLEClientReconnectTests: XCTestCase {
    func testFindDeviceReturnsFirstMatchAndStopsScanningThroughOwnedScanTermination() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let peripheral = FakePeripheral(identifier: UUID(), name: "Arc")

        let task = Task {
            try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: 1)
        }

        await waitForScanStart(on: central)
        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(localName: "Arc", serviceUUIDs: [], manufacturerData: nil),
            rssi: -50
        )

        let device = try await task.value
        await Task.yield()

        XCTAssertEqual(device.id, peripheral.identifier)
        XCTAssertEqual(device.name, "Arc")
        XCTAssertTrue(central.didStopScan)
        XCTAssertEqual(central.stopScanCallCount, 1)
    }

    func testFindDeviceTimesOut() async {
        let client = BLEClient(central: FakeCentralManager())

        do {
            _ = try await client.findDevice(matching: ScanFilter(name: "Missing"), timeout: 0.01)
            XCTFail("Expected scan timeout")
        } catch {
            XCTAssertEqual(error as? BLEError, .scanTimedOut)
        }
    }

    func testFindDeviceCancellationStopsScanAndThrowsOperationCancelled() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)

        let task = Task {
            try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: 1)
        }

        await waitForScanStart(on: central)
        task.cancel()

        guard let scanResult = await result(from: task) else {
            task.cancel()
            XCTFail("Cancelled scan did not complete")
            return
        }

        switch scanResult {
        case .success:
            XCTFail("Expected scan cancellation")
        case let .failure(error):
            XCTAssertEqual(error as? BLEError, .operationCancelled)
        }

        XCTAssertTrue(central.didStopScan)
        XCTAssertEqual(central.stopScanCallCount, 1)
    }

    func testFindDevicePreservesPoweredOffBluetoothError() async {
        let central = FakeCentralManager(state: .poweredOff)
        let client = BLEClient(central: central)

        do {
            _ = try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: 0.01)
            XCTFail("Expected bluetoothPoweredOff")
        } catch {
            XCTAssertEqual(error as? BLEError, .bluetoothPoweredOff)
        }

        XCTAssertNil(central.scannedServiceUUIDs)
        XCTAssertEqual(central.stopScanCallCount, 0)
    }

    func testReconnectRetrievesPeripheralBeforeScanning() async throws {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
        }

        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)

        let session = try await task.value
        XCTAssertEqual(session.device.id, id)
        XCTAssertEqual(session.device.name, "Arc")
        XCTAssertEqual(central.retrievedIdentifiers, [id])
        XCTAssertEqual(central.connectedIdentifiers, [id])
        XCTAssertNil(central.scannedServiceUUIDs)
    }

    func testReconnectFallsBackToServiceScanAndMatchesIdentifier() async throws {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let otherPeripheral = FakePeripheral(identifier: UUID(), name: "Other Arc")
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        let service = CBUUID(string: "FFF0")
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(
                identifier: id,
                fallbackScan: ScanFilter(serviceUUIDs: [service]),
                options: ConnectionOptions(timeout: 1)
            )
        }

        await waitForScanStart(on: central)
        central.discover(
            otherPeripheral,
            advertisement: BLEAdvertisement(localName: "Other Arc", serviceUUIDs: [service], manufacturerData: nil),
            rssi: -60
        )
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)

        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(localName: "Arc", serviceUUIDs: [service], manufacturerData: nil),
            rssi: -44
        )
        await Task.yield()
        await waitForConnectAttempt(on: central)
        central.completeConnection(peripheral)

        let session = try await task.value
        XCTAssertEqual(session.device.id, id)
        XCTAssertEqual(session.device.rssi, -44)
        XCTAssertEqual(central.retrievedIdentifiers, [id])
        XCTAssertEqual(central.scannedServiceUUIDs, [service])
        XCTAssertEqual(central.connectedIdentifiers, [id])
    }

    func testReconnectThrowsDeviceNotFoundWithoutFallback() async {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let client = BLEClient(central: central)

        do {
            _ = try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
            XCTFail("Expected deviceNotFound")
        } catch {
            XCTAssertEqual(error as? BLEError, .deviceNotFound(id))
        }

        XCTAssertEqual(central.retrievedIdentifiers, [id])
        XCTAssertNil(central.scannedServiceUUIDs)
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)
    }

    func testConnectTimeoutCancelsUnderlyingConnectionAndClearsCallbacks() async {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        do {
            _ = try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 0.01))
            XCTFail("Expected connectionTimedOut")
        } catch {
            XCTAssertEqual(error as? BLEError, .connectionTimedOut(id))
        }

        XCTAssertEqual(central.cancelledIdentifiers, [id])
        XCTAssertNil(central.onConnect)
        XCTAssertNil(central.onFailToConnect)
    }

    func testConnectFailureThrowsConnectionFailedAndClearsCallbacks() async {
        struct TestFailure: Error, CustomStringConvertible {
            var description: String { "link failed" }
        }

        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
        }

        await waitForConnectAttempt(on: central)
        central.failConnection(peripheral, error: TestFailure())

        do {
            _ = try await task.value
            XCTFail("Expected connectionFailed")
        } catch {
            XCTAssertEqual(error as? BLEError, .connectionFailed(id, underlying: "link failed"))
        }

        XCTAssertNil(central.onConnect)
        XCTAssertNil(central.onFailToConnect)
    }

    func testReconnectCancellationCancelsUnderlyingConnectionAndClearsCallbacks() async {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
        }

        await waitForConnectAttempt(on: central)
        task.cancel()

        guard let connectionResult = await result(from: task) else {
            task.cancel()
            XCTFail("Cancelled connection did not complete")
            return
        }

        switch connectionResult {
        case .success:
            XCTFail("Expected connection cancellation")
        case let .failure(error):
            XCTAssertEqual(error as? BLEError, .operationCancelled)
        }

        XCTAssertEqual(central.cancelledIdentifiers, [id])
        XCTAssertNil(central.onConnect)
        XCTAssertNil(central.onFailToConnect)
    }

    func testInvalidTimeoutDoesNotTrap() async {
        let client = BLEClient(central: FakeCentralManager())

        do {
            _ = try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: -.infinity)
            XCTFail("Expected scanTimedOut")
        } catch {
            XCTAssertEqual(error as? BLEError, .scanTimedOut)
        }
    }

    func testStartingSecondConnectionCancelsFirstAndKeepsSecondActive() async throws {
        let central = FakeCentralManager()
        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstPeripheral = FakePeripheral(identifier: firstID, name: "Arc One")
        let secondPeripheral = FakePeripheral(identifier: secondID, name: "Arc Two")
        central.retrievedPeripherals = [firstPeripheral, secondPeripheral]
        let client = BLEClient(central: central)

        let firstTask = Task {
            try await client.reconnect(identifier: firstID, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
        }

        await waitForConnectAttempt(on: central, count: 1)

        let secondTask = Task {
            try await client.reconnect(identifier: secondID, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
        }

        await waitForConnectAttempt(on: central, count: 2)

        guard let firstResult = await result(from: firstTask) else {
            firstTask.cancel()
            secondTask.cancel()
            XCTFail("First connection did not complete")
            return
        }

        switch firstResult {
        case .success:
            XCTFail("Expected first connection to be cancelled")
        case let .failure(error):
            XCTAssertEqual(error as? BLEError, .operationCancelled)
        }

        XCTAssertEqual(central.cancelledIdentifiers, [firstID])
        XCTAssertNotNil(central.onConnect)
        XCTAssertNotNil(central.onFailToConnect)

        central.completeConnection(firstPeripheral)
        central.completeConnection(secondPeripheral)

        let session = try await secondTask.value
        XCTAssertEqual(session.device.id, secondID)
        XCTAssertNil(central.onConnect)
        XCTAssertNil(central.onFailToConnect)
    }

    private func waitForScanStart(on central: FakeCentralManager) async {
        while central.scanForPeripheralsCallCount == 0 {
            await Task.yield()
        }
    }

    private func waitForConnectAttempt(on central: FakeCentralManager, count: Int = 1) async {
        while central.connectedIdentifiers.count < count {
            await Task.yield()
        }
    }

    private func result<T>(
        from task: Task<T, Error>,
        timeoutNanoseconds: UInt64 = 200_000_000
    ) async -> Result<T, Error>? {
        await withTaskGroup(of: Result<T, Error>?.self) { group in
            group.addTask {
                do {
                    return .success(try await task.value)
                } catch {
                    return .failure(error)
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }
}
