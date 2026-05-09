import Foundation

private final class FindDeviceAttempt {
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
    func scan(filter: ScanFilter) -> AsyncStream<BLEDevice> {
        AsyncStream { continuation in
            let scanID = UUID()

            do {
                try validateBluetoothReady()
            } catch {
                continuation.finish()
                return
            }

            startScan(id: scanID, filter: filter, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.finishScan(id: scanID)
            }
        }
    }

    func findDevice(
        matching filter: ScanFilter,
        timeout: TimeInterval
    ) async throws -> BLEDevice {
        try validateBluetoothReady()
        guard let timeoutNanoseconds = timeoutNanoseconds(timeout) else {
            throw BLEError.scanTimedOut
        }

        let stream = scan(filter: filter)
        let attempt = FindDeviceAttempt()

        return try await withCheckedThrowingContinuation { continuation in
            var scanTask: Task<Void, Never>?
            var timeoutTask: Task<Void, Never>?

            scanTask = Task {
                let device = await firstDevice(in: stream)
                attempt.finish {
                    timeoutTask?.cancel()
                    if let device {
                        continuation.resume(returning: device)
                    } else {
                        continuation.resume(throwing: BLEError.scanTimedOut)
                    }
                }
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                attempt.finish {
                    scanTask?.cancel()
                    continuation.resume(throwing: BLEError.scanTimedOut)
                }
            }
        }
    }

    private func firstDevice(in stream: AsyncStream<BLEDevice>) async -> BLEDevice? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
