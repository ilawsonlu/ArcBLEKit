import Foundation

public struct ConnectionOptions: Equatable, Sendable {
    public var timeout: TimeInterval
    public var autoReconnect: AutoReconnectPolicy

    public init(
        timeout: TimeInterval = 10,
        autoReconnect: AutoReconnectPolicy = .disabled
    ) {
        self.timeout = timeout
        self.autoReconnect = autoReconnect
    }
}

public enum AutoReconnectPolicy: Equatable, Sendable {
    case disabled
    case limited(maxAttempts: Int, delay: TimeInterval)
}
