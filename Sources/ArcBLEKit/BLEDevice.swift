#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

/// An immutable snapshot of a discovered BLE peripheral and its advertisement data.
public struct BLEDevice: Identifiable, Equatable, Sendable {
    /// The identifier CoreBluetooth assigns to the peripheral in the current app and device context.
    public let id: UUID
    /// The advertised local name, falling back to the CoreBluetooth peripheral name when available.
    public let name: String?
    /// The received signal strength from the latest advertisement.
    public let rssi: Int
    /// Service UUIDs included in the advertisement.
    public let advertisedServiceUUIDs: [CBUUID]
    /// Manufacturer-specific advertisement data.
    public let manufacturerData: Data?

    /// Creates a device snapshot.
    public init(
        id: UUID,
        name: String?,
        rssi: Int,
        advertisedServiceUUIDs: [CBUUID],
        manufacturerData: Data?
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.manufacturerData = manufacturerData
    }
}
