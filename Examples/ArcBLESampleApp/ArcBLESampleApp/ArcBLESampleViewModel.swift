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
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var savedIdentifierText = "None"
    @Published private(set) var statusText = "Idle"
    @Published private(set) var logs: [String] = ["Ready"]

    private let client = BLEClient()
    private var scanTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var session: PeripheralSession?
    private let savedIdentifierKey = "ArcBLESample.savedPeripheralIdentifier"

    init() {
        loadSavedIdentifier()
    }

    deinit {
        scanTask?.cancel()
        stateTask?.cancel()
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
            for await device in client.scan(filter: filter) {
                self.recordDiscoveredDevice(device)
            }
            self.finishScanIfNeeded(message: "Scan stopped")
        }
    }

    func stopScan() {
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
                    options: ConnectionOptions(timeout: 10)
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
                    options: ConnectionOptions(timeout: 10)
                )
                self.handleConnectedSession(session)
            } catch {
                self.handleError(error, prefix: "Reconnect failed")
            }
        }
    }

    func disconnect() {
        guard let session else { return }
        Task { [weak self] in
            await session.disconnect()
            self?.handleDisconnected()
        }
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

    private func makeServiceUUID() -> CBUUID? {
        let trimmed = serviceUUIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CBUUID(string: trimmed)
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
