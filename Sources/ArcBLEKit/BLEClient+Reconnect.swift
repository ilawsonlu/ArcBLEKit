import Foundation

private final class ConnectionAttempt {
    private let lock = NSLock()
    private var completed = false

    func finish(_ body: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        body()
    }
}

public extension BLEClient {
    func connect(
        to device: BLEDevice,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        guard let peripheral = rememberedPeripheral(identifier: device.id) else {
            throw BLEError.deviceNotFound(device.id)
        }

        return try await connect(peripheral: peripheral, device: device, options: options)
    }

    func reconnect(
        identifier: UUID,
        fallbackScan: ScanFilter?,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        let retrieved = central.retrievePeripherals(withIdentifiers: [identifier])

        if let peripheral = retrieved.first {
            remember(peripheral)
            let device = BLEDevice(
                id: peripheral.identifier,
                name: peripheral.name,
                rssi: 0,
                advertisedServiceUUIDs: [],
                manufacturerData: nil
            )
            return try await connect(peripheral: peripheral, device: device, options: options)
        }

        guard let fallbackScan else {
            throw BLEError.deviceNotFound(identifier)
        }

        var filter = fallbackScan
        filter.peripheralIdentifiers.insert(identifier)
        let device = try await findDevice(matching: filter, timeout: options.timeout)
        return try await connect(to: device, options: options)
    }

    private func connect(
        peripheral: PeripheralRepresenting,
        device: BLEDevice,
        options: ConnectionOptions
    ) async throws -> PeripheralSession {
        try validateBluetoothReady()

        let attempt = ConnectionAttempt()

        return try await withCheckedThrowingContinuation { continuation in
            var timeoutTask: Task<Void, Never>?

            func clearCallbacks() {
                self.central.onConnect = nil
                self.central.onFailToConnect = nil
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                attempt.finish {
                    clearCallbacks()
                    continuation.resume(throwing: BLEError.connectionTimedOut(peripheral.identifier))
                }
            }

            central.onConnect = { connectedPeripheral in
                guard connectedPeripheral.identifier == peripheral.identifier else { return }
                attempt.finish {
                    timeoutTask?.cancel()
                    clearCallbacks()
                    let session = PeripheralSession(
                        device: device,
                        peripheral: connectedPeripheral,
                        central: self.central,
                        options: options
                    )
                    continuation.resume(returning: session)
                }
            }

            central.onFailToConnect = { failedPeripheral, error in
                guard failedPeripheral.identifier == peripheral.identifier else { return }
                attempt.finish {
                    timeoutTask?.cancel()
                    clearCallbacks()
                    continuation.resume(
                        throwing: BLEError.connectionFailed(
                            peripheral.identifier,
                            underlying: error.map(String.init(describing:))
                        )
                    )
                }
            }

            central.connect(peripheral)
        }
    }
}
