#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class ScanOptionsAndUnlimitedTimeoutTests: XCTestCase {
    // MARK: - Scan options

    func testDefaultScanUsesDefaultOptions() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let task = Task { for try await _ in client.scan(filter: ScanFilter()) {} }
        defer { task.cancel() }

        try await waitUntil { central.scanForPeripheralsCallCount == 1 }
        XCTAssertEqual(central.scanOptions, ScanOptions())
    }

    func testScanPassesOptionsAndYieldsRepeatedAdvertisements() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let peripheral = FakePeripheral(name: "Sensor")
        let options = ScanOptions(allowDuplicates: true, solicitedServiceUUIDs: [CBUUID(string: "FEAA")])
        let received = TestLocked(wrappedValue: [BLEDevice]())

        let task = Task {
            for try await device in client.scan(filter: ScanFilter(namePrefix: "Sen"), options: options) {
                received.wrappedValue.append(device)
            }
        }
        defer { task.cancel() }

        try await waitUntil { central.scanForPeripheralsCallCount == 1 }
        XCTAssertEqual(central.scanOptions, options)

        for (rssi, byte) in [(-70, UInt8(1)), (-60, UInt8(2))] {
            central.discover(
                peripheral,
                advertisement: BLEAdvertisement(localName: "Sensor", serviceUUIDs: [], manufacturerData: Data([byte])),
                rssi: rssi
            )
        }

        try await waitUntil { received.wrappedValue.count == 2 }
        XCTAssertEqual(received.wrappedValue.map(\.rssi), [-70, -60])
        XCTAssertEqual(received.wrappedValue.map(\.manufacturerData), [Data([1]), Data([2])])
    }

    // MARK: - Unlimited timeouts

    func testFindDeviceWithUnlimitedTimeoutWaitsUntilMatch() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let peripheral = FakePeripheral(name: "Arc")
        let task = Task { try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: .infinity) }

        try await waitUntil { central.scanForPeripheralsCallCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(localName: "Arc", serviceUUIDs: [], manufacturerData: nil),
            rssi: -40
        )

        let device = try await task.value
        XCTAssertEqual(device.id, peripheral.identifier)
    }

    func testUnlimitedConnectionTimeoutStaysPendingUntilConnected() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)
        let task = Task {
            try await client.reconnect(
                identifier: peripheral.identifier,
                fallbackScan: nil,
                options: ConnectionOptions(timeout: .infinity)
            )
        }

        try await waitUntil { central.connectedIdentifiers.count == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(central.cancelledIdentifiers.isEmpty)
        XCTAssertNotNil(central.onConnect)

        central.completeConnection(peripheral)
        let session = try await task.value
        XCTAssertTrue(session.isConnected)
        await session.disconnect()
    }

    func testUnlimitedConnectionTimeoutCanBeCancelled() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)
        let task = Task {
            try await client.reconnect(
                identifier: peripheral.identifier,
                fallbackScan: nil,
                options: ConnectionOptions(timeout: .infinity)
            )
        }

        try await waitUntil { central.connectedIdentifiers.count == 1 }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? BLEError, .operationCancelled)
        }
        XCTAssertEqual(central.cancelledIdentifiers, [peripheral.identifier])
    }

    func testNonPositiveConnectionTimeoutStillFailsImmediately() async {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        for timeout in [0, -1, TimeInterval.nan] {
            do {
                _ = try await client.reconnect(
                    identifier: peripheral.identifier, fallbackScan: nil, options: ConnectionOptions(timeout: timeout)
                )
                XCTFail("Expected timeout for \(timeout)")
            } catch {
                XCTAssertEqual(error as? BLEError, .connectionTimedOut(peripheral.identifier))
            }
        }
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)
    }

    func testAutoReconnectWithUnlimitedTimeoutRestoresNotifications() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let service = FakeService(uuid: CBUUID(string: "FFF0"))
        let characteristic = FakeCharacteristic(uuid: CBUUID(string: "FFF1"), serviceUUID: service.uuid)
        let client = BLEClient(central: central)
        client.remember(peripheral)
        let device = BLEDevice(
            id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil
        )
        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(timeout: .infinity, autoReconnect: .limited(maxAttempts: 1, delay: 0))
            )
        }
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        addTeardownBlock { await session.disconnect() }

        let streamTask = Task { try await session.notifications(for: characteristic.uuid, service: service.uuid) }
        try await completeSubscription(peripheral, service: service, characteristic: characteristic, round: 1)
        var iterator = try await streamTask.value.makeAsyncIterator()

        central.disconnect(peripheral)
        try await waitUntil { central.connectedIdentifiers.count == 2 }
        central.completeConnection(peripheral)
        try await completeSubscription(peripheral, service: service, characteristic: characteristic, round: 2)

        try await waitUntil { session.connectionState == .ready }
        peripheral.emitNotification(characteristic: characteristic, data: Data([0x11]))
        let value = try await iterator.next()
        XCTAssertEqual(value, Data([0x11]))
    }

    // MARK: - Helpers

    private func completeSubscription(
        _ peripheral: FakePeripheral,
        service: FakeService,
        characteristic: FakeCharacteristic,
        round: Int
    ) async throws {
        try await waitUntil { peripheral.serviceDiscoveryRequests.count == round }
        peripheral.completeServiceDiscovery([service])
        try await waitUntil { peripheral.characteristicDiscoveryRequests.count == round }
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        try await waitUntil { peripheral.notifyChanges.count == round }
        peripheral.completeNotifySetup(characteristic: characteristic)
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
