#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

struct BLEAdvertisement: Equatable {
    let localName: String?
    let serviceUUIDs: [CBUUID]
    let manufacturerData: Data?
}
