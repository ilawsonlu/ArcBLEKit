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
        guard let timeoutNanoseconds = timeoutNanoseconds(options.timeout) else {
            throw BLEError.connectionTimedOut(peripheral.identifier)
        }

        let connectionID = UUID()
        let attempt = ConnectionAttempt()
        let cancellation = CancellationHandlerBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var timeoutTask: Task<Void, Never>?

                let cancelConnection = {
                    attempt.finish {
                        timeoutTask?.cancel()
                        _ = self.finishConnection(id: connectionID)
                        self.central.cancelPeripheralConnection(peripheral)
                        continuation.resume(throwing: BLEError.operationCancelled)
                    }
                }

                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    attempt.finish {
                        let ownsConnection = self.finishConnection(id: connectionID)
                        self.central.cancelPeripheralConnection(peripheral)
                        continuation.resume(
                            throwing: ownsConnection
                                ? BLEError.connectionTimedOut(peripheral.identifier)
                                : BLEError.operationCancelled
                        )
                    }
                }

                startConnection(id: connectionID, peripheral: peripheral, onSuperseded: cancelConnection) { connectedPeripheral in
                    guard connectedPeripheral.identifier == peripheral.identifier else { return }
                    attempt.finish {
                        timeoutTask?.cancel()
                        guard self.finishConnection(id: connectionID) else {
                            self.central.cancelPeripheralConnection(connectedPeripheral)
                            continuation.resume(throwing: BLEError.operationCancelled)
                            return
                        }
                        let session = PeripheralSession(
                            device: device,
                            peripheral: connectedPeripheral,
                            central: self.central,
                            options: options
                        )
                        continuation.resume(returning: session)
                    }
                } onFailToConnect: { failedPeripheral, error in
                    guard failedPeripheral.identifier == peripheral.identifier else { return }
                    attempt.finish {
                        timeoutTask?.cancel()
                        guard self.finishConnection(id: connectionID) else {
                            continuation.resume(throwing: BLEError.operationCancelled)
                            return
                        }
                        continuation.resume(
                            throwing: BLEError.connectionFailed(
                                peripheral.identifier,
                                underlying: error.map(String.init(describing:))
                            )
                        )
                    }
                }

                cancellation.set(cancelConnection)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
