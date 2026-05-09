#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

public extension PeripheralSession {
    func read(
        characteristic characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) async throws -> Data {
        try await operationQueue.run {
            let characteristic = try await resolveCharacteristic(characteristicUUID, service: serviceUUID)

            return try await withCheckedThrowingContinuation { continuation in
                peripheral.onValueRead = { readCharacteristic, data, error in
                    guard readCharacteristic.uuid == characteristicUUID else { return }
                    if let error {
                        continuation.resume(
                            throwing: BLEError.readFailed(
                                characteristicUUID,
                                underlying: String(describing: error)
                            )
                        )
                    } else {
                        continuation.resume(returning: data ?? Data())
                    }
                }
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func write(
        _ data: Data,
        to characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        type: CBCharacteristicWriteType
    ) async throws {
        try await operationQueue.run {
            let characteristic = try await resolveCharacteristic(characteristicUUID, service: serviceUUID)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peripheral.onValueWritten = { writtenCharacteristic, error in
                    guard writtenCharacteristic.uuid == characteristicUUID else { return }
                    if let error {
                        continuation.resume(
                            throwing: BLEError.writeFailed(
                                characteristicUUID,
                                underlying: String(describing: error)
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
                peripheral.writeValue(data, for: characteristic, type: type)
            }
        }
    }

    func notifications(
        for characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) async throws -> AsyncStream<Data> {
        try await operationQueue.run {
            let characteristic = try await resolveCharacteristic(characteristicUUID, service: serviceUUID)

            return try await withCheckedThrowingContinuation { continuation in
                peripheral.onNotificationStateUpdated = { updatedCharacteristic, error in
                    guard updatedCharacteristic.uuid == characteristicUUID else { return }
                    if let error {
                        continuation.resume(
                            throwing: BLEError.notificationSetupFailed(
                                characteristicUUID,
                                underlying: String(describing: error)
                            )
                        )
                    } else {
                        let stream = AsyncStream<Data> { streamContinuation in
                            self.peripheral.onNotificationValue = { notifiedCharacteristic, data in
                                guard notifiedCharacteristic.uuid == characteristicUUID else { return }
                                streamContinuation.yield(data)
                            }
                        }
                        continuation.resume(returning: stream)
                    }
                }
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    private func resolveCharacteristic(
        _ characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) async throws -> CharacteristicRepresenting {
        let service = try await resolveService(serviceUUID)

        if let cached = characteristicCache.characteristic(characteristicUUID, service: serviceUUID) {
            return cached
        }

        return try await withCheckedThrowingContinuation { continuation in
            peripheral.onCharacteristicsDiscovered = { discoveredService, characteristics, error in
                guard discoveredService.uuid == serviceUUID else { return }
                if let error {
                    _ = error
                    continuation.resume(
                        throwing: BLEError.characteristicNotFound(characteristicUUID, service: serviceUUID)
                    )
                    return
                }

                self.characteristicCache.store(characteristics: characteristics, serviceUUID: serviceUUID)
                guard let characteristic = self.characteristicCache.characteristic(
                    characteristicUUID,
                    service: serviceUUID
                ) else {
                    continuation.resume(
                        throwing: BLEError.characteristicNotFound(characteristicUUID, service: serviceUUID)
                    )
                    return
                }
                continuation.resume(returning: characteristic)
            }
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    private func resolveService(_ serviceUUID: CBUUID) async throws -> ServiceRepresenting {
        if let cached = characteristicCache.service(for: serviceUUID) {
            return cached
        }

        return try await withCheckedThrowingContinuation { continuation in
            peripheral.onServicesDiscovered = { services, error in
                if let error {
                    _ = error
                    continuation.resume(throwing: BLEError.serviceNotFound(serviceUUID))
                    return
                }

                self.characteristicCache.store(services: services)
                guard let service = self.characteristicCache.service(for: serviceUUID) else {
                    continuation.resume(throwing: BLEError.serviceNotFound(serviceUUID))
                    return
                }
                continuation.resume(returning: service)
            }
            peripheral.discoverServices([serviceUUID])
        }
    }
}
