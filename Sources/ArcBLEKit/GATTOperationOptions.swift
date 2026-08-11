#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

public enum GATTOperation: String, Equatable, Sendable {
    case serviceDiscovery
    case characteristicDiscovery
    case read
    case write
    case notificationSetup
    case writeWithoutResponseReady
}

/// Controls how ArcBLEKit resolves a service and characteristic before a GATT operation.
public enum GATTDiscoveryMode: Equatable, Sendable {
    /// Discover only the requested service and characteristic.
    case targeted

    /// Discover every service and every characteristic, matching CoreBluetooth's legacy
    /// `discoverServices(nil)` / `discoverCharacteristics(nil, for:)` flow.
    case all
}

public struct GATTOperationOptions: Equatable, Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }
}
