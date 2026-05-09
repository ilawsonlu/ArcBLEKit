public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case discoveringServices
    case ready
    case reconnecting(attempt: Int)
    case failed(BLEError)
}
