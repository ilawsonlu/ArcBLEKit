#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

public extension BLEClient {
    /// Returns system-connected peripherals implementing any supplied service.
    ///
    /// An empty service list returns no devices. Call `connect(to:options:)` on a result
    /// to establish this client's GATT session. Results contain no advertisement data;
    /// RSSI is unknown and represented as zero. This does not indicate audio readiness.
    func retrieveConnectedDevices(withServices services: [CBUUID]) throws -> [BLEDevice] {
        try validateBluetoothReady()
        guard !services.isEmpty else { return [] }
        return central.retrieveConnectedPeripherals(withServices: services).map { peripheral in
            remember(peripheral)
            return makeRetrievedDevice(peripheral)
        }
    }
}

extension BLEClient {
    func makeRetrievedDevice(_ peripheral: PeripheralRepresenting) -> BLEDevice {
        BLEDevice(
            id: peripheral.identifier,
            name: peripheral.name,
            rssi: 0,
            advertisedServiceUUIDs: [],
            manufacturerData: nil
        )
    }
}
