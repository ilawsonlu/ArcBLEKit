import Foundation

public extension BLEClient {
    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        switch bluetoothState {
        case .poweredOn:
            return
        case .unauthorized:
            throw BLEError.bluetoothUnauthorized
        case .unsupported:
            throw BLEError.bluetoothUnavailable
        case .poweredOff:
            throw BLEError.bluetoothPoweredOff
        case .unknown, .resetting:
            break
        }

        guard let timeoutNanoseconds = timeoutNanoseconds(timeout) else {
            throw BLEError.bluetoothReadyTimedOut
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        throw BLEError.bluetoothUnavailable
                    }

                    for await state in self.bluetoothStates {
                        try Task.checkCancellation()
                        switch state {
                        case .poweredOn:
                            return
                        case .unauthorized:
                            throw BLEError.bluetoothUnauthorized
                        case .unsupported:
                            throw BLEError.bluetoothUnavailable
                        case .poweredOff:
                            throw BLEError.bluetoothPoweredOff
                        case .unknown, .resetting:
                            continue
                        }
                    }
                    throw Task.isCancelled
                        ? BLEError.operationCancelled
                        : BLEError.bluetoothUnavailable
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw BLEError.bluetoothReadyTimedOut
                }

                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch is CancellationError {
            throw BLEError.operationCancelled
        }
    }
}
