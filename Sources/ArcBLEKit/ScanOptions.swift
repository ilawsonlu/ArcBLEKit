#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

/// CoreBluetooth scan behavior, independent of which advertisements a ``ScanFilter`` accepts.
public struct ScanOptions: Equatable, Sendable {
    /// Report every advertisement instead of coalescing repeats from the same peripheral.
    ///
    /// Enable this to track RSSI or read data that devices broadcast in their advertisements,
    /// such as sensor readings in manufacturer data. It increases power use, and iOS ignores it
    /// while the app is in the background.
    public var allowDuplicates: Bool

    /// Service UUIDs that peripherals solicit, matched by CoreBluetooth in addition to the
    /// filter's advertised services.
    public var solicitedServiceUUIDs: [CBUUID]

    /// Creates scan options. The defaults match CoreBluetooth's default scan.
    public init(allowDuplicates: Bool = false, solicitedServiceUUIDs: [CBUUID] = []) {
        self.allowDuplicates = allowDuplicates
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
    }
}
