import ArcBLEKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ArcBLESampleViewModel()
    @Environment(\.scenePhase) private var scenePhase

    private struct AutomaticConnectionContext: Equatable {
        let enabled: Bool
        let identifier: String
        let isForeground: Bool
    }

    var body: some View {
        NavigationView {
            Form {
                scanSection
                devicesSection
                reconnectSection
                statusSection
                gattSection
                notificationSection
                logSection
            }
            .navigationTitle("ArcBLE Sample")
        }
        .task(id: AutomaticConnectionContext(
            enabled: viewModel.autoConnectSavedDevice,
            identifier: viewModel.savedIdentifierText,
            isForeground: scenePhase == .active
        )) {
            await viewModel.runAutomaticConnection(isForeground: scenePhase == .active)
        }
    }

    private var scanSection: some View {
        Section(header: Text("Scan")) {
            TextField("Service UUID", text: $viewModel.serviceUUIDText)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)

            Button(action: toggleScan) {
                HStack {
                    Image(systemName: viewModel.isScanning ? "stop.fill" : "antenna.radiowaves.left.and.right")
                    Text(viewModel.isScanning ? "Stop Scan" : "Start Scan")
                }
            }
        }
    }

    private var devicesSection: some View {
        Section(header: Text("Discovered Devices")) {
            if viewModel.devices.isEmpty {
                Text(viewModel.isScanning ? "Scanning..." : "No devices yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.devices) { device in
                    DeviceRow(
                        device: device,
                        isConnected: viewModel.connectedDeviceID == device.id,
                        connect: {
                            viewModel.connect(to: device)
                        }
                    )
                    .disabled(viewModel.isConnecting)
                }
            }
        }
    }

    private var reconnectSection: some View {
        Section(header: Text("Saved Peripheral")) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Identifier")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(viewModel.savedIdentifierText)
                    .font(.footnote)
            }

            Toggle("Auto-connect Saved Device", isOn: $viewModel.autoConnectSavedDevice)

            Text("Restores the saved device when this app is active. Disconnect pauses automatic connection until you reconnect or enable it again.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: viewModel.reconnectSavedDevice) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Reconnect Saved Device")
                }
            }
            .disabled(viewModel.isConnecting)

            Button(action: viewModel.clearSavedIdentifier) {
                HStack {
                    Image(systemName: "trash")
                    Text("Clear Saved Identifier")
                }
                .foregroundColor(.red)
            }
        }
    }

    private var statusSection: some View {
        Section(header: Text("Connection")) {
            Toggle("Connect Audio Too", isOn: $viewModel.enableTransportBridging)

            Text("Requires a compatible dual-mode accessory. A control connection does not confirm that audio is ready.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Status")
                Spacer()
                Text(viewModel.statusText)
                    .foregroundColor(.secondary)
            }

            Button(action: viewModel.disconnect) {
                HStack {
                    Image(systemName: "xmark.circle")
                    Text("Disconnect")
                }
            }
            .disabled(!viewModel.canDisconnect)
        }
    }

    private var gattSection: some View {
        Section(header: Text("GATT Operations")) {
            uuidField(
                "Read Characteristic UUID",
                text: $viewModel.readCharacteristicUUIDText
            )

            HStack {
                Text("Last Read")
                Spacer()
                Text(viewModel.lastReadText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button(action: viewModel.readValue) {
                Label("Read Value", systemImage: "arrow.down.doc")
            }
            .disabled(viewModel.connectedDeviceID == nil)

            uuidField(
                "Write Characteristic UUID",
                text: $viewModel.writeCharacteristicUUIDText
            )
            TextField("Hex Payload", text: $viewModel.writePayloadHex)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))

            Picker("Write Mode", selection: $viewModel.writeWithResponse) {
                Text("With Response").tag(true)
                Text("Without Response").tag(false)
            }
            .pickerStyle(SegmentedPickerStyle())

            Button(action: viewModel.writeValue) {
                Label("Send Value", systemImage: "paperplane")
            }
            .disabled(viewModel.connectedDeviceID == nil)
        }
    }

    private var notificationSection: some View {
        Section(header: Text("Notifications")) {
            uuidField(
                "Notify Characteristic UUID",
                text: $viewModel.notifyCharacteristicUUIDText
            )

            HStack {
                Text("Latest")
                Spacer()
                Text(viewModel.latestNotificationText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button(
                action: {
                    if viewModel.isSubscribed {
                        viewModel.stopNotifications()
                    } else {
                        viewModel.startNotifications()
                    }
                }
            ) {
                Label(
                    viewModel.isSubscribed ? "Stop Notifications" : "Start Notifications",
                    systemImage: viewModel.isSubscribed ? "bell.slash" : "bell"
                )
            }
            .disabled(viewModel.connectedDeviceID == nil)
        }
    }

    private var logSection: some View {
        Section(header: Text("Log")) {
            ForEach(viewModel.logs, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func toggleScan() {
        if viewModel.isScanning {
            viewModel.stopScan()
        } else {
            viewModel.startScan()
        }
    }

    private func uuidField(
        _ title: String,
        text: Binding<String>
    ) -> some View {
        TextField(title, text: text)
            .autocapitalization(.allCharacters)
            .disableAutocorrection(true)
            .font(.system(.body, design: .monospaced))
    }
}

private struct DeviceRow: View {
    let device: BLEDevice
    let isConnected: Bool
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name?.isEmpty == false ? device.name! : "Unknown Device")
                        .font(.headline)
                    Text(device.id.uuidString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text(isConnected ? "Connected" : "Ready")
                    .font(.caption)
                    .foregroundColor(isConnected ? .green : .secondary)
                Spacer()
                Button(action: connect) {
                    Text(isConnected ? "Reconnect" : "Connect")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
