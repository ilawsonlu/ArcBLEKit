#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import ArcBLEKit
import Combine
import Foundation

@MainActor
final class ArcBLESampleViewModel: ObservableObject {
    @Published var serviceUUIDText = "FFF0"
    @Published var readCharacteristicUUIDText = "FFF1"
    @Published var writeCharacteristicUUIDText = "FFF2"
    @Published var notifyCharacteristicUUIDText = "FFF3"
    @Published var writePayloadHex = "01 02"
    @Published var writeWithResponse = true
    @Published var enableTransportBridging = false {
        didSet { defaults.set(enableTransportBridging, forKey: Self.bridgingKey) }
    }
    @Published var autoConnectSavedDevice = false {
        didSet {
            defaults.set(autoConnectSavedDevice, forKey: Self.autoConnectKey)
            if autoConnectSavedDevice { automaticConnectionSuppressed = false }
        }
    }
    @Published private(set) var isConnecting = false
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSubscribed = false
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var savedIdentifierText = "None"
    @Published private(set) var statusText = "Idle"
    @Published private(set) var lastReadText = "None"
    @Published private(set) var latestNotificationText = "None"
    @Published private(set) var logs: [String] = ["Ready"]

    private let client: BLEClient
    private let defaults: UserDefaults
    private static let autoConnectKey = "ArcBLESample.autoConnectSavedDevice"
    private static let bridgingKey = "ArcBLESample.enableTransportBridging"
    private static let savedServiceKey = "ArcBLESample.savedServiceUUID"
    private var connectionTask: Task<Void, Never>?
    private var connectionCleanupTask: Task<Void, Never>?
    private var connectionAttemptID: UUID?
    private var connectionIsAutomatic = false
    private var automaticConnectionSuppressed = false
    private var automaticRunID: UUID?
    private var connectionEventsTask: Task<Void, Never>?
    private var connectionEventsTaskID: UUID?
    private var scanTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var session: PeripheralSession?
    private let savedIdentifierKey = "ArcBLESample.savedPeripheralIdentifier"

    init(client: BLEClient = BLEClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        autoConnectSavedDevice = defaults.bool(forKey: Self.autoConnectKey)
        enableTransportBridging = defaults.bool(forKey: Self.bridgingKey)
        if let service = defaults.string(forKey: Self.savedServiceKey) {
            serviceUUIDText = service
        }
        loadSavedIdentifier()
    }

    var canDisconnect: Bool { session != nil || isConnecting }

    deinit {
        connectionTask?.cancel()
        connectionEventsTask?.cancel()
        scanTask?.cancel()
        stateTask?.cancel()
        notificationTask?.cancel()
    }

    func startScan() {
        guard scanTask == nil else { return }
        automaticConnectionSuppressed = true
        cancelPendingConnection(onlyAutomatic: true)
        guard let serviceUUID = makeServiceUUID() else {
            appendLog("Invalid service UUID: \(serviceUUIDText)")
            return
        }

        devices.removeAll()
        isScanning = true
        statusText = "Scanning"
        appendLog("Scanning for service \(serviceUUID.uuidString)")

        let filter = ScanFilter(serviceUUIDs: [serviceUUID])
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.waitUntilReady(timeout: 10)
                for try await device in client.scan(filter: filter) {
                    self.recordDiscoveredDevice(device)
                }
                self.finishScanIfNeeded(message: "Scan stopped")
            } catch let error as BLEError where error == .operationCancelled {
                self.finishScanIfNeeded(message: "Scan cancelled")
            } catch {
                self.finishScanIfNeeded(message: "Scan stopped")
                self.handleError(error, prefix: "Scan failed")
            }
        }
    }

    func stopScan() {
        guard scanTask != nil else { return }
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusText = "Idle"
        appendLog("Scan cancelled")
    }

    func connect(to device: BLEDevice) {
        automaticConnectionSuppressed = false
        let client = client
        let options = sampleConnectionOptions
        beginConnection(automatic: false, message: "Connecting to \(device.displayName)") {
            try await client.waitUntilReady(timeout: 10)
            return try await client.connect(to: device, options: options)
        }
    }

    func reconnectSavedDevice() {
        automaticConnectionSuppressed = false
        reconnectSavedDevice(automatic: false)
    }

    private func reconnectSavedDevice(automatic: Bool) {
        if automatic {
            guard autoConnectSavedDevice, !automaticConnectionSuppressed, session == nil else { return }
        }
        guard let identifier = savedIdentifier(), let serviceUUID = makeServiceUUID() else {
            if !automatic { appendLog("A saved identifier and valid service UUID are required") }
            return
        }
        let client = client
        let options = sampleConnectionOptions
        beginConnection(automatic: automatic, message: "Restoring \(identifier.uuidString)") {
            try await client.waitUntilReady(timeout: 10)
            if let device = try client.retrieveConnectedDevices(withServices: [serviceUUID])
                .first(where: { $0.id == identifier }) {
                return try await client.connect(to: device, options: options)
            }
            return try await client.reconnect(
                identifier: identifier,
                fallbackScan: ScanFilter(serviceUUIDs: [serviceUUID]),
                fallbackOnConnectionFailure: true,
                options: options
            )
        }
    }

    private func beginConnection(
        automatic: Bool,
        message: String,
        operation: @escaping () async throws -> PeripheralSession
    ) {
        guard connectionTask == nil else {
            appendLog("A connection request is already in progress")
            return
        }
        stopScan()
        stopNotifications()
        stateTask?.cancel()
        stateTask = nil
        let previousSession = session
        let previousCleanup = connectionCleanupTask
        session = nil
        connectedDeviceID = nil
        let attemptID = UUID()
        let serviceText = serviceUUIDText
        connectionAttemptID = attemptID
        connectionIsAutomatic = automatic
        isConnecting = true
        statusText = automatic ? "Restoring saved device" : "Connecting"
        appendLog(message)
        connectionTask = Task { [weak self] in
            await previousCleanup?.value
            await previousSession?.disconnect()
            guard !Task.isCancelled else { return }
            do {
                let newSession = try await operation()
                guard let self, self.connectionAttemptID == attemptID, !Task.isCancelled else {
                    await newSession.disconnect()
                    return
                }
                self.connectionTask = nil
                self.connectionAttemptID = nil
                self.isConnecting = false
                self.defaults.set(serviceText, forKey: Self.savedServiceKey)
                self.handleConnectedSession(newSession)
            } catch {
                guard let self, self.connectionAttemptID == attemptID else { return }
                self.connectionTask = nil
                self.connectionAttemptID = nil
                self.isConnecting = false
                if Task.isCancelled || error as? BLEError == .operationCancelled {
                    self.statusText = "Disconnected"
                } else {
                    self.handleError(error, prefix: "Connection failed")
                }
            }
        }
    }

    private func cancelPendingConnection(onlyAutomatic: Bool = false) {
        guard connectionTask != nil, !onlyAutomatic || connectionIsAutomatic else { return }
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionCleanupTask = connectionTask
        connectionTask = nil
        isConnecting = false
        statusText = "Disconnected"
    }

    func disconnect() {
        automaticConnectionSuppressed = true
        cancelPendingConnection()
        stateTask?.cancel()
        stateTask = nil
        let previousSession = session
        let previousCleanup = connectionCleanupTask
        handleDisconnected()
        connectionCleanupTask = Task {
            await previousCleanup?.value
            await previousSession?.disconnect()
        }
    }

    /// Scoped to the foreground SwiftUI task; preferences never force a background reconnect.
    func runAutomaticConnection(isForeground: Bool) async {
        guard isForeground, autoConnectSavedDevice, let identifier = savedIdentifier() else { return }
        let runID = UUID()
        automaticRunID = runID
        defer {
            if automaticRunID == runID {
                automaticRunID = nil
                connectionEventsTaskID = nil
                connectionEventsTask?.cancel()
                connectionEventsTask = nil
                cancelPendingConnection(onlyAutomatic: true)
            }
        }
        for await state in client.bluetoothStates {
            guard !Task.isCancelled, automaticRunID == runID else { return }
            if state == .poweredOn {
                guard !automaticConnectionSuppressed else {
                    appendLog("Automatic connection paused after user action")
                    continue
                }
                observeSystemConnections(identifier: identifier, runID: runID)
                reconnectSavedDevice(automatic: true)
            } else {
                connectionEventsTaskID = nil
                connectionEventsTask?.cancel()
                connectionEventsTask = nil
                cancelPendingConnection(onlyAutomatic: true)
                appendLog("Automatic connection waiting for Bluetooth: \(state)")
            }
        }
    }

    private func observeSystemConnections(identifier: UUID, runID: UUID) {
        guard connectionEventsTask == nil else { return }
        #if os(iOS)
        let client = client
        let taskID = UUID()
        connectionEventsTaskID = taskID
        connectionEventsTask = Task { [weak self] in
            defer {
                if self?.connectionEventsTaskID == taskID {
                    self?.connectionEventsTaskID = nil
                    self?.connectionEventsTask = nil
                }
            }
            do {
                for try await event in client.connectionEvents(
                    matching: ConnectionEventFilter(peripheralIdentifiers: [identifier])
                ) {
                    guard !Task.isCancelled, let self, self.automaticRunID == runID else { return }
                    self.appendLog("System peer: \(event.kind), \(event.device.id)")
                    if event.kind == .connected, event.device.id == self.savedIdentifier() {
                        self.reconnectSavedDevice(automatic: true)
                    }
                }
            } catch {
                if !Task.isCancelled, self?.automaticRunID == runID {
                    self?.appendLog("System event observation failed: \(error)")
                }
            }
        }
        #endif
    }

    func readValue() {
        guard let session else {
            appendLog("Connect a device before reading")
            return
        }
        guard let serviceUUID = makeUUID(serviceUUIDText),
              let characteristicUUID = makeUUID(readCharacteristicUUIDText) else {
            appendLog("Invalid read service or characteristic UUID")
            return
        }

        appendLog("Reading \(characteristicUUID.uuidString)")
        Task { [weak self] in
            do {
                let data = try await session.read(
                    characteristic: characteristicUUID,
                    service: serviceUUID
                )
                let hex = Self.hexString(data)
                self?.lastReadText = hex
                self?.appendLog("Read: \(hex)")
            } catch {
                self?.handleError(error, prefix: "Read failed")
            }
        }
    }

    func writeValue() {
        guard let session else {
            appendLog("Connect a device before writing")
            return
        }
        guard let serviceUUID = makeUUID(serviceUUIDText),
              let characteristicUUID = makeUUID(writeCharacteristicUUIDText) else {
            appendLog("Invalid write service or characteristic UUID")
            return
        }
        guard let data = Self.data(fromHex: writePayloadHex) else {
            appendLog("Invalid hex payload")
            return
        }

        let writeType: CBCharacteristicWriteType = writeWithResponse
            ? .withResponse
            : .withoutResponse
        appendLog(
            "Writing \(data.count) bytes \(writeWithResponse ? "with" : "without") response"
        )

        Task { [weak self] in
            do {
                try await session.write(
                    data,
                    to: characteristicUUID,
                    service: serviceUUID,
                    type: writeType
                )
                self?.appendLog("Write complete: \(Self.hexString(data))")
            } catch {
                self?.handleError(error, prefix: "Write failed")
            }
        }
    }

    func startNotifications() {
        guard notificationTask == nil else { return }
        guard let session else {
            appendLog("Connect a device before subscribing")
            return
        }
        guard let serviceUUID = makeUUID(serviceUUIDText),
              let characteristicUUID = makeUUID(
                notifyCharacteristicUUIDText
              ) else {
            appendLog("Invalid notification service or characteristic UUID")
            return
        }

        appendLog("Subscribing to \(characteristicUUID.uuidString)")
        notificationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await session.notifications(
                    for: characteristicUUID,
                    service: serviceUUID
                )
                self.isSubscribed = true
                for try await data in stream {
                    let hex = Self.hexString(data)
                    self.latestNotificationText = hex
                    self.appendLog("Notification: \(hex)")
                }
                self.finishNotifications(message: "Notifications stopped")
            } catch let error as BLEError where error == .operationCancelled {
                self.finishNotifications(message: "Notifications stopped")
            } catch {
                self.handleError(error, prefix: "Notification failed")
                self.finishNotifications(message: "Notifications stopped")
            }
        }
    }

    func stopNotifications() {
        guard notificationTask != nil else { return }
        notificationTask?.cancel()
        notificationTask = nil
        isSubscribed = false
        appendLog("Stopping notifications")
    }

    func clearSavedIdentifier() {
        automaticConnectionSuppressed = true
        cancelPendingConnection()
        defaults.removeObject(forKey: savedIdentifierKey)
        defaults.removeObject(forKey: Self.savedServiceKey)
        loadSavedIdentifier()
        appendLog("Cleared saved identifier")
    }

    private func recordDiscoveredDevice(_ device: BLEDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    private func finishScanIfNeeded(message: String) {
        scanTask = nil
        isScanning = false
        if connectedDeviceID == nil {
            statusText = "Idle"
        }
        appendLog(message)
    }

    private func handleConnectedSession(_ session: PeripheralSession) {
        self.session = session
        connectedDeviceID = session.device.id
        statusText = "Connected"
        saveIdentifier(session.device.id)
        appendLog("Connected to \(session.device.displayName)")
        observeConnectionStates(session)
    }

    private func handleDisconnected() {
        notificationTask?.cancel()
        notificationTask = nil
        isSubscribed = false
        session = nil
        connectedDeviceID = nil
        statusText = "Disconnected"
        appendLog("Disconnected")
    }

    private func handleError(_ error: Error, prefix: String) {
        statusText = "Error"
        appendLog("\(prefix): \(error)")
    }

    private func observeConnectionStates(_ session: PeripheralSession) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in session.connectionStates {
                guard !Task.isCancelled, let self, self.session === session else { return }
                self.handleConnectionState(state)
            }
        }
    }

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connected:
            connectedDeviceID = session?.device.id
            statusText = "Connected"
        case .connecting:
            statusText = "Connecting"
        case .disconnected:
            connectedDeviceID = nil
            statusText = "Disconnected"
        case .reconnecting(let attempt):
            statusText = "Reconnecting #\(attempt)"
        case .discoveringServices:
            statusText = "Discovering services"
        case .ready:
            statusText = "Ready"
        case .failed(let error):
            connectedDeviceID = nil
            session = nil
            statusText = "Failed"
            appendLog("Connection failed: \(error)")
        }
        appendLog("State: \(state)")
    }

    private func saveIdentifier(_ identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: savedIdentifierKey)
        loadSavedIdentifier()
    }

    private func savedIdentifier() -> UUID? {
        guard let rawValue = defaults.string(forKey: savedIdentifierKey) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func loadSavedIdentifier() {
        savedIdentifierText = savedIdentifier()?.uuidString ?? "None"
    }

    private var sampleConnectionOptions: ConnectionOptions {
        ConnectionOptions(
            timeout: 10,
            autoReconnect: .limited(maxAttempts: 3, delay: 1),
            enableTransportBridging: enableTransportBridging
        )
    }

    private func makeServiceUUID() -> CBUUID? {
        makeUUID(serviceUUIDText)
    }

    private func makeUUID(_ value: String) -> CBUUID? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CBUUID(string: trimmed)
    }

    private func finishNotifications(message: String) {
        notificationTask = nil
        isSubscribed = false
        appendLog(message)
    }

    private static func hexString(_ data: Data) -> String {
        guard !data.isEmpty else { return "(empty)" }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func data(fromHex input: String) -> Data? {
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",:-")
        )
        let compact = input.components(separatedBy: separators).joined()
        guard !compact.isEmpty,
              compact.count.isMultiple(of: 2),
              compact.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                      .contains($0)
              }) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let nextIndex = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }
        return Data(bytes)
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.insert("[\(formatter.string(from: Date()))] \(message)", at: 0)
        if logs.count > 80 {
            logs.removeLast(logs.count - 80)
        }
    }
}

private extension BLEDevice {
    var displayName: String {
        name?.isEmpty == false ? name! : id.uuidString
    }
}
