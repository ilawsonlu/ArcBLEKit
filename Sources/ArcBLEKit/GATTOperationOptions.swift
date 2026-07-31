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

public struct GATTOperationOptions: Equatable, Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }
}
