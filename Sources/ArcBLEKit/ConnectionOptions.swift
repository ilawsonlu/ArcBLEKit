import Foundation

/// Timeout and recovery behavior for a peripheral connection.
public struct ConnectionOptions: Equatable, Sendable {
    /// The maximum number of seconds allowed for connection and reconnect operations.
    public var timeout: TimeInterval
    /// The policy applied after an unexpected disconnect.
    public var autoReconnect: AutoReconnectPolicy

    /// Creates connection options.
    public init(
        timeout: TimeInterval = 10,
        autoReconnect: AutoReconnectPolicy = .disabled
    ) {
        self.timeout = timeout
        self.autoReconnect = autoReconnect
    }
}

/// Recovery behavior after an unexpected peripheral disconnect.
public enum AutoReconnectPolicy: Equatable, Sendable {
    /// Finish the session after an unexpected disconnect.
    case disabled
    /// Retry a finite number of times, waiting `delay` seconds before each attempt.
    case limited(maxAttempts: Int, delay: TimeInterval)
}
