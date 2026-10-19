import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class ArcBLESampleViewModelTests: XCTestCase {
    private final class MemoryDefaults: UserDefaults {
        private var values: [String: Any] = [:]

        init(values: [String: Any] = [:]) {
            super.init(suiteName: "ArcBLESampleTests.\(UUID())")!
            self.values = values
        }

        override func object(forKey key: String) -> Any? { values[key] }
        override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func removeObject(forKey key: String) { values[key] = nil }
    }

    @MainActor
    func testDefaultPreferencesDoNotAutoConnect() async {
        let central = FakeCentralManager()
        let model = ArcBLESampleViewModel(client: BLEClient(central: central), defaults: MemoryDefaults())

        await model.runAutomaticConnection(isForeground: true)

        XCTAssertFalse(model.autoConnectSavedDevice)
        XCTAssertFalse(model.enableTransportBridging)
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)
    }

    @MainActor
    func testBackgroundDoesNotStartAutomaticRecovery() async {
        let central = FakeCentralManager()
        let model = makeModel(central: central, identifier: UUID())

        await model.runAutomaticConnection(isForeground: false)

        XCTAssertTrue(central.connectedIdentifiers.isEmpty)
        XCTAssertTrue(central.retrievedIdentifiers.isEmpty)
    }

    @MainActor
    func testForegroundReusesSystemConnectionAndCoalescesRequests() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.systemConnectedPeripherals = [peripheral]
        let model = makeModel(central: central, identifier: peripheral.identifier)
        let foreground = Task { await model.runAutomaticConnection(isForeground: true) }
        defer { foreground.cancel() }

        try await waitUntil { central.connectedIdentifiers.count == 1 }
        model.reconnectSavedDevice()
        XCTAssertEqual(central.connectedIdentifiers, [peripheral.identifier])
        XCTAssertTrue(central.connectionOptions[0].enableTransportBridging)
        XCTAssertEqual(central.connectedServiceQueries, [[CBUUID(string: "5A00")]])
        XCTAssertTrue(central.retrievedIdentifiers.isEmpty)
        central.completeConnection(peripheral)
        try await waitUntil { model.connectedDeviceID == peripheral.identifier }

        foreground.cancel()
        await foreground.value
        XCTAssertEqual(model.connectedDeviceID, peripheral.identifier)
        XCTAssertTrue(central.cancelledIdentifiers.isEmpty)
        model.disconnect()
    }

    @MainActor
    func testManualDisconnectCancelsPendingRecoveryAndSuppressesNextReadyEvent() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let model = makeModel(central: central, identifier: peripheral.identifier)
        let foreground = Task { await model.runAutomaticConnection(isForeground: true) }
        defer { foreground.cancel() }
        try await waitUntil { central.connectedIdentifiers.count == 1 }

        model.disconnect()
        try await waitUntil { central.cancelledIdentifiers.contains(peripheral.identifier) }
        central.updateState(.poweredOn)
        try await waitUntil { model.logs.contains { $0.contains("Automatic connection paused") } }

        XCTAssertEqual(central.connectedIdentifiers.count, 1)
        XCTAssertNil(model.connectedDeviceID)
        XCTAssertFalse(model.isConnecting)

        model.reconnectSavedDevice()
        try await waitUntil { central.connectedIdentifiers.count == 2 }
        central.completeConnection(peripheral)
        try await waitUntil { model.connectedDeviceID == peripheral.identifier }
        model.disconnect()
    }

    @MainActor
    func testBluetoothInitiallyOffWaitsAndRecoversWhenPoweredOn() async throws {
        let central = FakeCentralManager(state: .poweredOff)
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let model = makeModel(central: central, identifier: peripheral.identifier)
        let foreground = Task { await model.runAutomaticConnection(isForeground: true) }
        defer { foreground.cancel() }
        try await waitUntil { model.logs.contains { $0.contains("waiting for Bluetooth") } }
        XCTAssertTrue(central.connectedIdentifiers.isEmpty)

        central.updateState(.poweredOn)
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        central.completeConnection(peripheral)
        try await waitUntil { model.connectedDeviceID == peripheral.identifier }
        model.disconnect()
    }

    @MainActor
    func testClearingSavedDeviceCancelsRecoveryAndDoesNotSaveLateSuccess() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let model = makeModel(central: central, identifier: peripheral.identifier)
        let foreground = Task { await model.runAutomaticConnection(isForeground: true) }
        defer { foreground.cancel() }
        try await waitUntil { central.connectedIdentifiers.count == 1 }

        model.clearSavedIdentifier()
        try await waitUntil { central.cancelledIdentifiers.contains(peripheral.identifier) }
        central.completeConnection(peripheral)

        XCTAssertEqual(model.savedIdentifierText, "None")
        XCTAssertNil(model.connectedDeviceID)
        XCTAssertFalse(model.isConnecting)
    }

    @MainActor
    func testLeavingForegroundCancelsAutomaticRequest() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let model = makeModel(central: central, identifier: peripheral.identifier)
        let foreground = Task { await model.runAutomaticConnection(isForeground: true) }
        try await waitUntil { central.connectedIdentifiers.count == 1 }

        foreground.cancel()
        await foreground.value
        try await waitUntil { central.cancelledIdentifiers.contains(peripheral.identifier) }

        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.connectedDeviceID)
    }

    @MainActor
    func testLeavingForegroundPreservesManualConnectionRequest() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        central.retrievedPeripherals = [peripheral]
        let model = makeModel(central: central, identifier: peripheral.identifier)
        model.reconnectSavedDevice()
        try await waitUntil { central.connectedIdentifiers.count == 1 }
        let foreground = Task { await model.runAutomaticConnection(isForeground: true) }
        defer { foreground.cancel() }
        try await waitUntil { model.logs.contains { $0.contains("already in progress") } }

        foreground.cancel()
        await foreground.value

        XCTAssertTrue(model.isConnecting)
        XCTAssertTrue(central.cancelledIdentifiers.isEmpty)
        central.completeConnection(peripheral)
        try await waitUntil { model.connectedDeviceID == peripheral.identifier }
        model.disconnect()
    }

    @MainActor
    private func makeModel(central: FakeCentralManager, identifier: UUID) -> ArcBLESampleViewModel {
        ArcBLESampleViewModel(client: BLEClient(central: central), defaults: MemoryDefaults(values: [
            "ArcBLESample.savedPeripheralIdentifier": identifier.uuidString,
            "ArcBLESample.savedServiceUUID": "5A00",
            "ArcBLESample.autoConnectSavedDevice": true,
            "ArcBLESample.enableTransportBridging": true
        ]))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "ArcBLESampleTests.Timeout", code: 1)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
