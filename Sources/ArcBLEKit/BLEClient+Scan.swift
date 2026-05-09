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

            startScan(id: scanID, filter: filter, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.finishScan(id: scanID)
            }
        }
    }
}
