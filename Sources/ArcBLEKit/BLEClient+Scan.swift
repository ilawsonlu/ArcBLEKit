import Foundation

private final class FindDeviceAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var scanTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installScanTask(_ task: Task<Void, Never>) {
        install(task, isScanTask: true)
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        install(task, isScanTask: false)
    }

    func finish(_ body: @Sendable () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let scanTask = scanTask
        let timeoutTask = timeoutTask
        self.scanTask = nil
        self.timeoutTask = nil
        lock.unlock()

        scanTask?.cancel()
        timeoutTask?.cancel()
        body()
    }

    private func install(
        _ task: Task<Void, Never>,
        isScanTask: Bool
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            task.cancel()
            return
        }
        if isScanTask {
            scanTask = task
        } else {
            timeoutTask = task
        }
        lock.unlock()
    }
}

public extension BLEClient {
    /// Scans for peripherals matching a filter.
    ///
    /// Only one scan can be active on a client. Starting another scan finishes the previous
    /// stream. Cancel the consuming task or stop iterating to stop the CoreBluetooth scan.
    ///
    /// - Parameter filter: Service, identifier, name, and manufacturer-data constraints.
    /// - Returns: A stream of matching advertisement snapshots.
    /// - Throws: ``BLEError`` when Bluetooth is unavailable while scanning.
    func scan(
        filter: ScanFilter
    ) -> AsyncThrowingStream<BLEDevice, Error> {
        AsyncThrowingStream { continuation in
            let scanID = UUID()

            do {
                try validateBluetoothReady()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            startScan(id: scanID, filter: filter, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.finishScan(id: scanID)
            }
        }
    }

    /// Returns the first peripheral matching a filter.
    /// - Parameters:
    ///   - filter: Constraints applied to advertisements.
    ///   - timeout: The maximum number of seconds to wait for a match.
    /// - Returns: The first matching device.
    /// - Throws: ``BLEError/scanTimedOut``, ``BLEError/operationCancelled``, or a Bluetooth state error.
    func findDevice(
        matching filter: ScanFilter,
        timeout: TimeInterval
    ) async throws -> BLEDevice {
        try validateBluetoothReady()
        guard let timeoutNanoseconds = timeoutNanoseconds(timeout) else {
            throw BLEError.scanTimedOut
        }

        let scanID = UUID()
        let stream = AsyncThrowingStream<BLEDevice, Error> { continuation in
            startScan(id: scanID, filter: filter, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.finishScan(id: scanID)
            }
        }
        let attempt = FindDeviceAttempt()
        let cancellation = CancellationHandlerBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let scanTask = Task {
                    do {
                        let device = try await firstDevice(in: stream)
                        attempt.finish {
                            self.finishScan(id: scanID)
                            if let device {
                                continuation.resume(returning: device)
                            } else {
                                continuation.resume(
                                    throwing: BLEError.scanTimedOut
                                )
                            }
                        }
                    } catch {
                        attempt.finish {
                            self.finishScan(id: scanID)
                            continuation.resume(throwing: error)
                        }
                    }
                }
                attempt.installScanTask(scanTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    attempt.finish {
                        self.finishScan(id: scanID)
                        continuation.resume(throwing: BLEError.scanTimedOut)
                    }
                }
                attempt.installTimeoutTask(timeoutTask)

                cancellation.set {
                    attempt.finish {
                        self.finishScan(id: scanID)
                        continuation.resume(throwing: BLEError.operationCancelled)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func firstDevice(
        in stream: AsyncThrowingStream<BLEDevice, Error>
    ) async throws -> BLEDevice? {
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
    }
}
