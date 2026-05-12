import ArcBLEKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ArcBLESampleViewModel()

    var body: some View {
        NavigationView {
            Form {
                scanSection
                devicesSection
                reconnectSection
                statusSection
                logSection
            }
            .navigationTitle("ArcBLE Sample")
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

            Button(action: viewModel.reconnectSavedDevice) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Reconnect Saved Device")
                }
            }

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
