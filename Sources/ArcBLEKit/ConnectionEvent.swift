#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

/// System connection event matching. Services and identifiers are combined with OR.
/// An empty filter matches nothing. These are not advertisement scan constraints.
public struct ConnectionEventFilter: Equatable, Sendable {
    public var serviceUUIDs: [CBUUID]
    public var peripheralIdentifiers: Set<UUID>

    public init(serviceUUIDs: [CBUUID] = [], peripheralIdentifiers: Set<UUID> = []) {
        self.serviceUUIDs = serviceUUIDs
        self.peripheralIdentifiers = peripheralIdentifiers
    }
}

/// A system peer event, independent of this client's GATT session and audio route.
public struct ConnectionEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case connected
        case disconnected
    }

    public let kind: Kind
    /// A snapshot with unknown RSSI (zero) and no advertisement fields.
    public let device: BLEDevice
}
