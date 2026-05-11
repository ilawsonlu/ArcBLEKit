import Foundation

public final class PeripheralSession {
    public let device: BLEDevice
    let peripheral: PeripheralRepresenting
    let central: CentralManaging
    let options: ConnectionOptions
    let characteristicCache = CharacteristicCache()
    let operationQueue = SessionOperationQueue()

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public let connectionStates: AsyncStream<ConnectionState>

    init(
        device: BLEDevice,
        peripheral: PeripheralRepresenting,
        central: CentralManaging,
        options: ConnectionOptions
    ) {
        self.device = device
        self.peripheral = peripheral
        self.central = central
        self.options = options

        var continuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionStates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        emit(.connected)
    }

    func emit(_ state: ConnectionState) {
        stateContinuation.yield(state)
    }

    func handleDisconnect(error: Error?) {
        emit(.disconnected)

        guard case let .limited(maxAttempts, delay) = options.autoReconnect,
              maxAttempts > 0 else {
            return
        }

        Task {
            for attempt in 1...maxAttempts {
                emit(.reconnecting(attempt: attempt))
                try? await Task.sleep(nanoseconds: reconnectDelayNanoseconds(delay))
                emit(.connecting)
                central.connect(peripheral)
                return
            }
        }
    }

    public func disconnect() async {
        central.cancelPeripheralConnection(peripheral)
        emit(.disconnected)
        stateContinuation.finish()
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
