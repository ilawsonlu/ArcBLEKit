import Foundation

public final class PeripheralSession: @unchecked Sendable {
    typealias ReconnectAction = () async throws -> PeripheralRepresenting
    typealias TerminationHandler = (PeripheralSession) -> Void

    public let device: BLEDevice
    let peripheral: PeripheralRepresenting
    let central: CentralManaging
    let options: ConnectionOptions
    let characteristicCache = CharacteristicCache()
    let operationQueue = SessionOperationQueue()
    let operationCoordinator = GATTOperationCoordinator()
    let notificationRegistry = NotificationRegistry()

    private let reconnectAction: ReconnectAction?
    private let onTermination: TerminationHandler
    private let lifecycleLock = NSLock()
    private var connected = true
    private var terminated = false
    private var manualDisconnectRequested = false
    private var reconnectInProgress = false
    private var reconnectTask: Task<Void, Never>?

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public let connectionStates: AsyncStream<ConnectionState>

    var isConnected: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return connected && !terminated
    }

    init(
        device: BLEDevice,
        peripheral: PeripheralRepresenting,
        central: CentralManaging,
        options: ConnectionOptions,
        reconnectAction: ReconnectAction? = nil,
        onTermination: @escaping TerminationHandler = { _ in }
    ) {
        self.device = device
        self.peripheral = peripheral
        self.central = central
        self.options = options
        self.reconnectAction = reconnectAction
        self.onTermination = onTermination

        var continuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionStates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

        self.peripheral.onEvent = { [weak self] event in
            self?.handlePeripheralEvent(event)
        }
        emit(.connected)
        emit(.ready)
    }

    func emit(_ state: ConnectionState) {
        stateContinuation.yield(state)
    }

    func ensureConnected() throws {
        guard isConnected else {
            throw BLEError.disconnected(device.id, underlying: nil)
        }
    }

    func handleDisconnect(error: Error?) {
        let disconnectError = BLEError.disconnected(
            device.id,
            underlying: error.map(String.init(describing:))
        )

        lifecycleLock.lock()
        guard !terminated, !manualDisconnectRequested else {
            lifecycleLock.unlock()
            return
        }
        connected = false
        let alreadyReconnecting = reconnectInProgress
        lifecycleLock.unlock()

        operationCoordinator.failAll(with: disconnectError)
        Task {
            await operationQueue.cancelAll(with: disconnectError)
        }
        characteristicCache.clear()

        guard !alreadyReconnecting else {
            return
        }

        emit(.disconnected)
        guard case let .limited(maxAttempts, delay) = options.autoReconnect,
              maxAttempts > 0,
              reconnectAction != nil else {
            finishSession(throwing: disconnectError)
            return
        }

        lifecycleLock.lock()
        guard !terminated, !manualDisconnectRequested else {
            lifecycleLock.unlock()
            return
        }
        reconnectInProgress = true
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runReconnect(
                maxAttempts: maxAttempts,
                delay: delay,
                initialError: disconnectError
            )
        }
        reconnectTask = task
        lifecycleLock.unlock()
    }

    public func disconnect() async {
        guard let task = beginManualDisconnect() else {
            return
        }
        task.cancel()

        let cancellationError = BLEError.operationCancelled
        operationCoordinator.failAll(with: cancellationError)
        await operationQueue.cancelAll(with: cancellationError)
        notificationRegistry.finishAll(throwing: cancellationError)
        characteristicCache.clear()
        peripheral.onEvent = nil
        central.cancelPeripheralConnection(peripheral)
        emit(.disconnected)
        stateContinuation.finish()
        onTermination(self)
    }

    private func beginManualDisconnect() -> Task<Void, Never>? {
        lifecycleLock.lock()
        guard !terminated else {
            lifecycleLock.unlock()
            return nil
        }
        manualDisconnectRequested = true
        connected = false
        terminated = true
        reconnectInProgress = false
        let task = reconnectTask
        reconnectTask = nil
        lifecycleLock.unlock()
        return task ?? Task {}
    }

    func invalidate() {
        finishSession(throwing: BLEError.operationCancelled)
    }

    private func runReconnect(
        maxAttempts: Int,
        delay: TimeInterval,
        initialError: BLEError
    ) async {
        var lastError = initialError

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled, shouldContinueReconnecting else {
                return
            }

            emit(.reconnecting(attempt: attempt))
            do {
                try await Task.sleep(
                    nanoseconds: reconnectDelayNanoseconds(delay)
                )
            } catch {
                return
            }

            guard !Task.isCancelled, shouldContinueReconnecting else {
                return
            }
            emit(.connecting)

            do {
                guard let reconnectAction else {
                    throw lastError
                }
                _ = try await reconnectAction()
                guard setConnectedAfterReconnect() else {
                    central.cancelPeripheralConnection(peripheral)
                    return
                }
                characteristicCache.clear()
                emit(.connected)

                if !notificationRegistry.activeIDs().isEmpty {
                    do {
                        try await restoreNotifications(
                            options: GATTOperationOptions(
                                timeout: options.timeout
                            )
                        )
                    } catch {
                        guard shouldContinueReconnecting else {
                            return
                        }
                        let bleError = mapToBLEError(error)
                        emit(.failed(bleError))
                        central.cancelPeripheralConnection(peripheral)
                        finishSession(throwing: bleError)
                        return
                    }
                }

                guard shouldContinueReconnecting else {
                    return
                }
                guard isConnected else {
                    throw BLEError.disconnected(
                        device.id,
                        underlying: nil
                    )
                }
                emit(.ready)
                finishReconnectSuccessfully()
                return
            } catch {
                guard shouldContinueReconnecting else {
                    return
                }
                lastError = mapToBLEError(error)
                markReconnectAttemptFailed()
            }
        }

        emit(.failed(lastError))
        finishSession(throwing: lastError)
    }

    private var shouldContinueReconnecting: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return !terminated && !manualDisconnectRequested && reconnectInProgress
    }

    private func setConnectedAfterReconnect() -> Bool {
        lifecycleLock.lock()
        guard !terminated,
              !manualDisconnectRequested,
              reconnectInProgress else {
            lifecycleLock.unlock()
            return false
        }
        connected = true
        lifecycleLock.unlock()
        return true
    }

    private func markReconnectAttemptFailed() {
        lifecycleLock.lock()
        connected = false
        lifecycleLock.unlock()
    }

    private func finishReconnectSuccessfully() {
        lifecycleLock.lock()
        reconnectInProgress = false
        reconnectTask = nil
        lifecycleLock.unlock()
    }

    private func finishSession(throwing error: BLEError) {
        lifecycleLock.lock()
        guard !terminated else {
            lifecycleLock.unlock()
            return
        }
        terminated = true
        connected = false
        reconnectInProgress = false
        let task = reconnectTask
        reconnectTask = nil
        lifecycleLock.unlock()

        if task?.isCancelled == false {
            task?.cancel()
        }
        operationCoordinator.failAll(with: error)
        Task {
            await operationQueue.cancelAll(with: error)
        }
        notificationRegistry.finishAll(throwing: error)
        characteristicCache.clear()
        peripheral.onEvent = nil
        stateContinuation.finish()
        onTermination(self)
    }

    private func mapToBLEError(_ error: Error) -> BLEError {
        if let bleError = error as? BLEError {
            return bleError
        }
        return .connectionFailed(
            device.id,
            underlying: String(describing: error)
        )
    }

    private func reconnectDelayNanoseconds(_ delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else {
            return 0
        }

        let nanoseconds = delay * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds)
    }
}
