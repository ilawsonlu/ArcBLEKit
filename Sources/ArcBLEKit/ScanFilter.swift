#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

/// Constraints used to select BLE advertisements.
///
/// Nonempty and non-`nil` properties are combined with logical AND. Service UUIDs are also passed
/// to CoreBluetooth to reduce the scan at the system level.
public struct ScanFilter: Equatable, Sendable {
    /// Service UUIDs that the peripheral must advertise.
    public var serviceUUIDs: [CBUUID]
    /// CoreBluetooth peripheral identifiers accepted by the filter.
    public var peripheralIdentifiers: Set<UUID>
    /// An exact advertised or peripheral name.
    public var name: String?
    /// A required prefix for the advertised or peripheral name.
    public var namePrefix: String?
    /// A required prefix for manufacturer-specific advertisement data.
    public var manufacturerDataPrefix: Data?

    /// Creates a scan filter. Empty and `nil` values do not restrict results.
    public init(
        serviceUUIDs: [CBUUID] = [],
        peripheralIdentifiers: Set<UUID> = [],
        name: String? = nil,
        namePrefix: String? = nil,
        manufacturerDataPrefix: Data? = nil
    ) {
        self.serviceUUIDs = serviceUUIDs
        self.peripheralIdentifiers = peripheralIdentifiers
        self.name = name
        self.namePrefix = namePrefix
        self.manufacturerDataPrefix = manufacturerDataPrefix
    }

    func matches(_ device: BLEDevice) -> Bool {
        if !peripheralIdentifiers.isEmpty && !peripheralIdentifiers.contains(device.id) {
            return false
        }

        if let name, device.name != name {
            return false
        }

        if let namePrefix {
            guard let deviceName = device.name, deviceName.hasPrefix(namePrefix) else {
                return false
            }
        }

        if let manufacturerDataPrefix {
            guard let manufacturerData = device.manufacturerData,
                  manufacturerData.starts(with: manufacturerDataPrefix) else {
                return false
            }
        }

        return true
    }
}
