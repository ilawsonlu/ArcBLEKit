import Foundation

public extension BLEClient {
    func scan(filter: ScanFilter) -> AsyncStream<BLEDevice> {
        AsyncStream { continuation in
            let scanID = UUID()

            do {
                try validateBluetoothReady()
            } catch {
                continuation.finish()
                return
            }

            beginScan(id: scanID, continuation: continuation)

            central.onDiscover = { [weak self] peripheral, advertisement, rssi in
                guard let self else { return }
                guard self.isActiveScan(id: scanID) else { return }
                let device = BLEAdvertisementParser.makeDevice(
                    peripheral: peripheral,
                    advertisement: advertisement,
                    rssi: rssi
                )
                guard filter.matches(device) else { return }
                self.remember(peripheral)
                continuation.yield(device)
            }

            central.scanForPeripherals(
                withServices: filter.serviceUUIDs.isEmpty ? nil : filter.serviceUUIDs
            )

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                guard self.endScan(id: scanID) else { return }
                self.central.onDiscover = nil
                self.central.stopScan()
            }
        }
    }
}
