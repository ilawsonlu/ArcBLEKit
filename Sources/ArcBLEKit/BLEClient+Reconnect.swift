import Foundation

private final class ConnectionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func finish(_ body: @Sendable () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        body()
    }
}

public extension BLEClient {
    /// Connects to a device obtained from this client's scan, retrieval, or connection events.
    /// - Parameters:
    ///   - device: A device obtained from this client.
    ///   - options: Connection timeout and automatic reconnect policy.
    /// - Returns: A session for performing GATT operations.
    /// - Throws: ``BLEError`` if the device is unknown, Bluetooth is unavailable, or the connection fails.
    func connect(
        to device: BLEDevice,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        guard let peripheral = rememberedPeripheral(identifier: device.id) else {
            throw BLEError.deviceNotFound(device.id)
        }

        return try await connect(peripheral: peripheral, device: device, options: options)
    }

    /// Reconnects using a saved identifier, scanning only when CoreBluetooth cannot retrieve it.
    ///
    /// This overload preserves the original method signature, including stored function references.
    /// The timeout is shared by retrieval, scanning, and connection.
    func reconnect(
        identifier: UUID,
        fallbackScan: ScanFilter?,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        try await reconnect(
            identifier: identifier,
            fallbackScan: fallbackScan,
            fallbackOnConnectionFailure: false,
            options: options
        )
    }

    /// Reconnects to a peripheral using a saved CoreBluetooth identifier.
    ///
    /// The client first asks CoreBluetooth to retrieve the peripheral. If retrieval does not
    /// return it, the client can scan with the supplied fallback filter while also requiring the
    /// saved identifier.
    ///
    /// - Parameters:
    ///   - identifier: A previously saved ``BLEDevice/id``.
    ///   - fallbackScan: Scan constraints to use when CoreBluetooth cannot retrieve the peripheral.
    ///   - fallbackOnConnectionFailure: Also scan after a retrieved peripheral fails to connect.
    ///     When enabled with a fallback filter, half the remaining budget is reserved for recovery.
    ///   - options: Total reconnect time budget and subsequent session recovery policy.
    /// - Returns: A connected peripheral session.
    /// - Throws: ``BLEError`` when the peripheral cannot be found or connected.
    func reconnect(
        identifier: UUID,
        fallbackScan: ScanFilter?,
        fallbackOnConnectionFailure: Bool,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        try validateBluetoothReady()
        if Task.isCancelled { throw BLEError.operationCancelled }
        guard timeoutNanoseconds(options.timeout) != nil else {
            throw BLEError.connectionTimedOut(identifier)
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        func remainingBudget() throws -> TimeInterval {
            if Task.isCancelled { throw BLEError.operationCancelled }
            let remaining = options.timeout - (ProcessInfo.processInfo.systemUptime - startedAt)
            guard remaining > 0 else { throw BLEError.connectionTimedOut(identifier) }
            return remaining
        }
        let retrieved = central.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = retrieved.first {
            remember(peripheral)
            let budget = try remainingBudget()
            do {
                return try await connect(
                    peripheral: peripheral,
                    device: makeRetrievedDevice(peripheral),
                    options: options,
                    timeout: fallbackOnConnectionFailure && fallbackScan != nil ? budget / 2 : budget
                )
            } catch {
                guard fallbackOnConnectionFailure, fallbackScan != nil,
                      let bleError = error as? BLEError else { throw error }
                switch bleError {
                case .connectionFailed, .connectionTimedOut: break
                default: throw error
                }
            }
        }

        guard let fallbackScan else { throw BLEError.deviceNotFound(identifier) }
        var filter = fallbackScan
        filter.peripheralIdentifiers = [identifier]
        let device = try await findDevice(matching: filter, timeout: remainingBudget())
        guard let peripheral = rememberedPeripheral(identifier: identifier) else {
            throw BLEError.deviceNotFound(identifier)
        }
        return try await connect(
            peripheral: peripheral, device: device, options: options, timeout: remainingBudget()
        )
    }

    private func connect(
        peripheral: PeripheralRepresenting,
        device: BLEDevice,
        options: ConnectionOptions,
        timeout: TimeInterval? = nil
    ) async throws -> PeripheralSession {
        var attemptOptions = options
        attemptOptions.timeout = timeout ?? options.timeout
        let connectedPeripheral = try await establishConnection(
            peripheral: peripheral,
            options: attemptOptions
        )
        remember(connectedPeripheral)

        let session = PeripheralSession(
            device: device,
            peripheral: connectedPeripheral,
            central: central,
            options: options,
            reconnectAction: { [weak self] in
                guard let self else {
                    throw BLEError.bluetoothUnavailable
                }
                return try await self.establishConnection(
                    peripheral: connectedPeripheral,
                    options: options
                )
            },
            onTermination: { [weak self] session in
                self?.remove(session)
            }
        )
        remember(session)
        return session
    }

    private func establishConnection(
        peripheral: PeripheralRepresenting,
        options: ConnectionOptions
    ) async throws -> PeripheralRepresenting {
        try validateBluetoothReady()
        guard let timeoutNanoseconds = timeoutNanoseconds(options.timeout) else {
            throw BLEError.connectionTimedOut(peripheral.identifier)
        }

        let connectionID = UUID()
        let attempt = ConnectionAttempt()
        let cancellation = CancellationHandlerBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelConnection: @Sendable () -> Void = {
                    attempt.finish {
                        _ = self.finishConnection(id: connectionID)
                        self.central.cancelPeripheralConnection(peripheral)
                        continuation.resume(throwing: BLEError.operationCancelled)
                    }
                }

                startConnection(id: connectionID, peripheral: peripheral, options: options, onSuperseded: cancelConnection) { connectedPeripheral in
                    guard connectedPeripheral.identifier == peripheral.identifier else { return }
                    attempt.finish {
                        guard self.finishConnection(id: connectionID) else {
                            self.central.cancelPeripheralConnection(connectedPeripheral)
                            continuation.resume(throwing: BLEError.operationCancelled)
                            return
                        }
                        continuation.resume(returning: connectedPeripheral)
                    }
                } onFailToConnect: { failedPeripheral, error in
                    guard failedPeripheral.identifier == peripheral.identifier else { return }
                    attempt.finish {
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

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
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
                attempt.installTimeoutTask(timeoutTask)
                cancellation.set(cancelConnection)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
