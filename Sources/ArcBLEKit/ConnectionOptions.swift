import Foundation

/// Timeout and recovery behavior for a peripheral connection.
public struct ConnectionOptions: Equatable, Sendable {
    /// The maximum connection duration; `reconnect` shares this budget across retrieval, scan, and connection.
    ///
    /// Pass `.infinity` to keep a pending CoreBluetooth connection until the peripheral comes into
    /// range or the task is cancelled. Automatic reconnect then also waits indefinitely for each
    /// attempt, and notification restoration uses the default GATT timeout. Zero, negative, and
    /// NaN values fail immediately with ``BLEError/connectionTimedOut(_:)``.
    public var timeout: TimeInterval
    /// The policy applied after an unexpected disconnect.
    public var autoReconnect: AutoReconnectPolicy

    /// Requests classic Bluetooth profiles after an LE connection on compatible dual-mode hardware.
    /// This does not guarantee audio readiness. Ignored on macOS.
    public var enableTransportBridging: Bool

    /// Creates connection options.
    public init(
        timeout: TimeInterval = 10,
        autoReconnect: AutoReconnectPolicy = .disabled,
        enableTransportBridging: Bool = false
    ) {
        self.timeout = timeout
        self.autoReconnect = autoReconnect
        self.enableTransportBridging = enableTransportBridging
    }
}

/// Recovery behavior after an unexpected peripheral disconnect.
public enum AutoReconnectPolicy: Equatable, Sendable {
    /// Finish the session after an unexpected disconnect.
    case disabled
    /// Retry a finite number of times, waiting `delay` seconds before each attempt.
    case limited(maxAttempts: Int, delay: TimeInterval)
}
