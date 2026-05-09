@preconcurrency import CoreBluetooth
import Foundation

public struct ScanFilter: Equatable, Sendable {
    public var serviceUUIDs: [CBUUID]
    public var peripheralIdentifiers: Set<UUID>
    public var name: String?
    public var namePrefix: String?
    public var manufacturerDataPrefix: Data?

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
