#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class BLEClientConnectedDevicesTests: XCTestCase {
    func testPowerCycleRegistersCurrentFilterAgain() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let filter = ConnectionEventFilter(peripheralIdentifiers: [UUID()])
        let stream = client.makeConnectionEvents(matching: filter)
        XCTAssertEqual(central.connectionEventRegistrationCount, 1)

        central.updateState(.poweredOff)
        XCTAssertEqual(central.connectionEventRegistrationCount, 1)
        central.updateState(.poweredOn)
        XCTAssertEqual(central.connectionEventRegistrationCount, 2)
        XCTAssertEqual(central.registeredEventFilter, filter)

        let task = Task { for try await _ in stream {} }
        task.cancel()
        _ = try await task.value
    }

    func testCancellingWhilePoweredOffDoesNotRestoreOldFilter() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let stream = client.makeConnectionEvents(matching: .init(peripheralIdentifiers: [UUID()]))
        central.updateState(.poweredOff)
        let task = Task { for try await _ in stream {} }
        task.cancel()
        _ = try await task.value
        central.updateState(.poweredOn)

        XCTAssertNil(central.registeredEventFilter)
    }

    func testEventCanArriveDuringRegistrationWithoutBlockingDelivery() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let peripheral = FakePeripheral()
        var deliveredDuringRegistration = false
        central.onRegisterConnectionEvents = { [weak central] filter in
            guard filter != nil, let central else { return }
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                central.onConnectionEvent?(.connected, peripheral)
                delivered.signal()
            }
            deliveredDuringRegistration = delivered.wait(timeout: .now() + 1) == .success
        }
        let stream = client.makeConnectionEvents(matching: .init(peripheralIdentifiers: [peripheral.identifier]))
        XCTAssertTrue(deliveredDuringRegistration)
        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.device.id, peripheral.identifier)
    }

    func testReleasingClientClearsRegistrationAndFinishesEventStream() async throws {
        let central = FakeCentralManager()
        var client: BLEClient? = BLEClient(central: central)
        let stream = client!.makeConnectionEvents(matching: .init(peripheralIdentifiers: [UUID()]))
        var iterator = stream.makeAsyncIterator()

        client = nil

        guard central.registeredEventFilter == nil else {
            XCTFail("Releasing the client must clear its system event registration")
            return
        }
        let event = try await iterator.next()
        XCTAssertNil(event)
    }

    func testSystemConnectedDeviceCanBeConnectedWithoutScanning() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral(identifier: UUID(), name: "Arc")
        central.systemConnectedPeripherals = [peripheral]
        let client = BLEClient(central: central)
        let service = CBUUID(string: "FFF0")
        let devices = try client.retrieveConnectedDevices(withServices: [service])
        XCTAssertEqual(central.connectedServiceQueries, [[service]])
        XCTAssertEqual(devices.first?.id, peripheral.identifier)
        XCTAssertEqual(devices.first?.rssi, 0)
        XCTAssertEqual(devices.first?.advertisedServiceUUIDs, [])
        XCTAssertNil(devices.first?.manufacturerData)
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)
        let task = Task {
            try await client.connect(to: XCTUnwrap(devices.first), options: .init(enableTransportBridging: true))
        }
        while central.connectedIdentifiers.isEmpty { await Task.yield() }
        central.completeConnection(peripheral)
        let session = try await task.value
        XCTAssertEqual(session.device.id, peripheral.identifier)
        XCTAssertTrue(central.connectionOptions[0].enableTransportBridging)
        XCTAssertEqual(central.scanForPeripheralsCallCount, 0)
        await session.disconnect()
    }

    func testEmptyQueryDoesNotAskCoreBluetoothForAllDevices() throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        XCTAssertEqual(try client.retrieveConnectedDevices(withServices: []), [])
        XCTAssertTrue(central.connectedServiceQueries.isEmpty)
    }

    func testQueryRequiresReadyBluetooth() {
        let central = FakeCentralManager(state: .poweredOff)
        XCTAssertThrowsError(try BLEClient(central: central).retrieveConnectedDevices(withServices: [CBUUID(string: "FFF0")])) {
            XCTAssertEqual($0 as? BLEError, .bluetoothPoweredOff)
        }
        XCTAssertTrue(central.connectedServiceQueries.isEmpty)
    }

    func testSystemEventCachesDeviceWithoutCompletingPendingConnection() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let peripheral = FakePeripheral()
        let filter = ConnectionEventFilter(peripheralIdentifiers: [peripheral.identifier])
        let stream = client.makeConnectionEvents(matching: filter)
        var iterator = stream.makeAsyncIterator()
        XCTAssertEqual(central.registeredEventFilter, filter)
        central.onConnectionEvent?(.connected, peripheral)
        let event = try await iterator.next()
        XCTAssertEqual(event?.kind, .connected)
        XCTAssertTrue(client.rememberedPeripheral(identifier: peripheral.identifier) === peripheral)
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)
        let device = try XCTUnwrap(event?.device)
        let task = Task { try await client.connect(to: device) }
        while central.connectedIdentifiers.isEmpty { await Task.yield() }
        central.onConnectionEvent?(.disconnected, peripheral)
        XCTAssertNotNil(central.onConnect)
        central.completeConnection(peripheral)
        let session = try await task.value
        await session.disconnect()
    }

    func testReplacingEventStreamDoesNotClearNewRegistration() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let first = client.makeConnectionEvents(matching: .init(serviceUUIDs: [CBUUID(string: "FFF0")]))
        var oldIterator = first.makeAsyncIterator()
        let filter = ConnectionEventFilter(peripheralIdentifiers: [UUID()])
        let second = client.makeConnectionEvents(matching: filter)
        let oldEvent = try await oldIterator.next()
        XCTAssertNil(oldEvent)
        XCTAssertEqual(central.registeredEventFilter, filter)
        let task = Task { for try await _ in second {} }
        task.cancel()
        _ = try await task.value
        XCTAssertNil(central.registeredEventFilter)
    }

    func testEmptyEventFilterEndsPriorStreamAndClearsRegistration() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let first = client.makeConnectionEvents(matching: .init(peripheralIdentifiers: [UUID()]))
        var oldIterator = first.makeAsyncIterator()
        var emptyIterator = client.makeConnectionEvents(matching: .init()).makeAsyncIterator()
        let oldEvent = try await oldIterator.next()
        let emptyEvent = try await emptyIterator.next()
        XCTAssertNil(oldEvent)
        XCTAssertNil(emptyEvent)
        XCTAssertNil(central.registeredEventFilter)
    }

    func testPoweredOffEventStreamFailsWithoutRegistering() async {
        let central = FakeCentralManager(state: .poweredOff)
        let client = BLEClient(central: central)
        var iterator = client.makeConnectionEvents(matching: .init(serviceUUIDs: [CBUUID(string: "FFF0")])).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected Bluetooth power error")
        } catch {
            XCTAssertEqual(error as? BLEError, .bluetoothPoweredOff)
        }
        XCTAssertNil(central.registeredEventFilter)
    }
}
