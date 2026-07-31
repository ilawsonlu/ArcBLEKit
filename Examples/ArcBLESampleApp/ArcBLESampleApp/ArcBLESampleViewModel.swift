#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import ArcBLEKit
import Foundation

@MainActor
final class ArcBLESampleViewModel: ObservableObject {
    @Published var serviceUUIDText = "FFF0"
    @Published var readCharacteristicUUIDText = "FFF1"
    @Published var writeCharacteristicUUIDText = "FFF2"
    @Published var notifyCharacteristicUUIDText = "FFF3"
    @Published var writePayloadHex = "01 02"
    @Published var writeWithResponse = true
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSubscribed = false
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var savedIdentifierText = "None"
    @Published private(set) var statusText = "Idle"
    @Published private(set) var lastReadText = "None"
    @Published private(set) var latestNotificationText = "None"
    @Published private(set) var logs: [String] = ["Ready"]

    private let client = BLEClient()
    private var scanTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var session: PeripheralSession?
    private let savedIdentifierKey = "ArcBLESample.savedPeripheralIdentifier"

    init() {
        loadSavedIdentifier()
    }

    deinit {
        scanTask?.cancel()
        stateTask?.cancel()
        notificationTask?.cancel()
    }

    func startScan() {
        guard scanTask == nil else { return }
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
        stopScan()
        statusText = "Connecting"
        appendLog("Connecting to \(device.displayName)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await client.connect(
                    to: device,
                    options: sampleConnectionOptions
                )
                self.handleConnectedSession(session)
            } catch {
                self.handleError(error, prefix: "Connect failed")
            }
        }
    }

    func reconnectSavedDevice() {
        guard let savedIdentifier = savedIdentifier() else {
            appendLog("No saved peripheral identifier")
            return
        }
        guard let serviceUUID = makeServiceUUID() else {
            appendLog("Invalid service UUID: \(serviceUUIDText)")
            return
        }

        stopScan()
        statusText = "Reconnecting"
        appendLog("Reconnecting to \(savedIdentifier.uuidString)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await client.reconnect(
                    identifier: savedIdentifier,
                    fallbackScan: ScanFilter(serviceUUIDs: [serviceUUID]),
                    options: sampleConnectionOptions
                )
                self.handleConnectedSession(session)
            } catch {
                self.handleError(error, prefix: "Reconnect failed")
            }
        }
    }

    func disconnect() {
        guard let session else { return }
        stopNotifications()
        Task { [weak self] in
            await session.disconnect()
            self?.handleDisconnected()
        }
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
        UserDefaults.standard.removeObject(forKey: savedIdentifierKey)
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
                self?.handleConnectionState(state)
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
        UserDefaults.standard.set(identifier.uuidString, forKey: savedIdentifierKey)
        loadSavedIdentifier()
    }

    private func savedIdentifier() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: savedIdentifierKey) else {
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
            autoReconnect: .limited(maxAttempts: 3, delay: 1)
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
