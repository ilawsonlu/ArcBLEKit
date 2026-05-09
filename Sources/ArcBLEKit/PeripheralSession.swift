import Foundation

public final class PeripheralSession {
    public let device: BLEDevice
    let peripheral: PeripheralRepresenting
    let central: CentralManaging
    let options: ConnectionOptions

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

    public func disconnect() async {
        central.cancelPeripheralConnection(peripheral)
        emit(.disconnected)
        stateContinuation.finish()
    }
}
