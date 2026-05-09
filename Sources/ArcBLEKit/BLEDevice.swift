#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

public struct BLEDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServiceUUIDs: [CBUUID]
    public let manufacturerData: Data?

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
