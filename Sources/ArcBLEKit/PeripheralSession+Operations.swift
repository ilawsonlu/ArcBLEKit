#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

public extension PeripheralSession {
    /// Reads a characteristic value.
    /// - Parameters:
    ///   - characteristicUUID: The characteristic to read.
    ///   - serviceUUID: The service containing the characteristic.
    ///   - options: The discovery and read timeout.
    /// - Returns: The value returned by the peripheral, or empty data when CoreBluetooth supplies no value.
    /// - Throws: ``BLEError`` when discovery, validation, timeout, cancellation, or the read fails.
    func read(
        characteristic characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        options: GATTOperationOptions = .init()
    ) async throws -> Data {
        try ensureConnected()

        return try await operationQueue.run {
            try self.ensureConnected()
            let characteristic = try await self.resolveCharacteristic(
                characteristicUUID,
                service: serviceUUID,
                options: options
            )
            guard characteristic.properties.contains(.read) else {
                throw BLEError.unsupportedCharacteristicOperation(
                    characteristicUUID,
                    operation: .read
                )
            }

            let id = GATTCharacteristicID(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID
            )
            let event = try await self.operationCoordinator.perform(
                key: .read(id),
                timeout: options.timeout
            ) {
                self.peripheral.readValue(for: characteristic)
            }

            guard case let .valueUpdated(_, data, error) = event else {
                throw BLEError.readFailed(characteristicUUID, underlying: nil)
            }
            if let error {
                throw BLEError.readFailed(
                    characteristicUUID,
                    underlying: String(describing: error)
                )
            }
            return data ?? Data()
        }
    }

    /// Writes data to a characteristic.
    ///
    /// Writes validate the characteristic property and maximum payload length. A write without
    /// response waits until CoreBluetooth indicates that the peripheral can accept more data.
    ///
    /// - Parameters:
    ///   - data: The payload to write.
    ///   - characteristicUUID: The destination characteristic.
    ///   - serviceUUID: The service containing the characteristic.
    ///   - type: Whether CoreBluetooth should request a response.
    ///   - options: The discovery, backpressure, and response timeout.
    /// - Throws: ``BLEError`` when discovery, validation, timeout, cancellation, or the write fails.
    func write(
        _ data: Data,
        to characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        type: CBCharacteristicWriteType,
        options: GATTOperationOptions = .init()
    ) async throws {
        try ensureConnected()

        try await operationQueue.run {
            try self.ensureConnected()
            let characteristic = try await self.resolveCharacteristic(
                characteristicUUID,
                service: serviceUUID,
                options: options
            )
            try self.validateWriteSupport(
                characteristic,
                characteristicUUID: characteristicUUID,
                type: type
            )

            let maximumLength = self.peripheral.maximumWriteValueLength(for: type)
            guard data.count <= maximumLength else {
                throw BLEError.valueTooLong(
                    actual: data.count,
                    maximum: maximumLength
                )
            }

            if type == .withoutResponse {
                try await self.waitUntilReadyToWriteWithoutResponse(options: options)
                self.peripheral.writeValue(
                    data,
                    for: characteristic,
                    type: .withoutResponse
                )
                return
            }

            let id = GATTCharacteristicID(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID
            )
            let event = try await self.operationCoordinator.perform(
                key: .write(id),
                timeout: options.timeout
            ) {
                self.peripheral.writeValue(
                    data,
                    for: characteristic,
                    type: .withResponse
                )
            }

            guard case let .valueWritten(_, error) = event else {
                throw BLEError.writeFailed(characteristicUUID, underlying: nil)
            }
            if let error {
                throw BLEError.writeFailed(
                    characteristicUUID,
                    underlying: String(describing: error)
                )
            }
        }
    }

    /// Subscribes to characteristic value updates.
    ///
    /// Multiple streams for the same service and characteristic share the underlying CoreBluetooth
    /// notification. Active streams are restored after a successful automatic reconnect.
    ///
    /// - Parameters:
    ///   - characteristicUUID: The characteristic that produces updates.
    ///   - serviceUUID: The service containing the characteristic.
    ///   - options: The discovery and subscription timeout.
    ///   - allowUnsupportedProperties: Whether to try subscribing when the characteristic omits
    ///     the `.notify` and `.indicate` properties.
    ///   - discoveryMode: Targeted discovery by default, or unfiltered discovery for legacy firmware.
    /// - Returns: A stream of characteristic values.
    /// - Throws: ``BLEError`` when discovery, validation, or notification setup fails.
    func notifications(
        for characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        options: GATTOperationOptions = .init(),
        allowUnsupportedProperties: Bool = false,
        discoveryMode: GATTDiscoveryMode = .targeted
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try ensureConnected()

        return try await operationQueue.run {
            try self.ensureConnected()
            let id = GATTCharacteristicID(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID
            )
            let characteristic = try await self.resolveCharacteristic(
                characteristicUUID,
                service: serviceUUID,
                options: options,
                discoveryMode: discoveryMode
            )

            if !allowUnsupportedProperties,
               !characteristic.properties.contains(.notify),
               !characteristic.properties.contains(.indicate) {
                throw BLEError.unsupportedCharacteristicOperation(
                    characteristicUUID,
                    operation: .notificationSetup
                )
            }

            if !self.notificationRegistry.hasSubscribers(for: id) {
                do {
                    try await self.setNotifications(
                        true,
                        characteristic: characteristic,
                        id: id,
                        options: options
                    )
                } catch let error as BLEError {
                    guard allowUnsupportedProperties,
                          case .notificationSetupFailed = error
                    else {
                        throw error
                    }
                }
            }

            let subscriberID = UUID()
            return AsyncThrowingStream { continuation in
                self.notificationRegistry.add(
                    continuation,
                    subscriberID: subscriberID,
                    characteristic: characteristic,
                    for: id
                )
                continuation.onTermination = { [weak self] _ in
                    self?.notificationTerminated(
                        subscriberID: subscriberID,
                        id: id,
                        options: options
                    )
                }
            }
        }
    }

    /// Returns the maximum payload length accepted by CoreBluetooth for a write type.
    /// - Parameter type: The response behavior for the write.
    func maximumWriteValueLength(
        for type: CBCharacteristicWriteType
    ) -> Int {
        peripheral.maximumWriteValueLength(for: type)
    }
}

extension PeripheralSession {
    func handlePeripheralEvent(_ event: PeripheralEvent) {
        switch event {
        case .servicesDiscovered:
            operationCoordinator.resolve(key: .serviceDiscovery, event: event)

        case let .characteristicsDiscovered(service, _, _):
            operationCoordinator.resolve(
                key: .characteristicDiscovery(serviceUUID: service.uuid),
                event: event
            )

        case let .valueUpdated(characteristic, data, error):
            let id = GATTCharacteristicID(
                serviceUUID: characteristic.serviceUUID,
                characteristicUUID: characteristic.uuid
            )
            let completedRead = operationCoordinator.resolve(
                key: .read(id),
                event: event
            )

            if let error {
                if !completedRead,
                   notificationRegistry.hasSubscribers(for: id) {
                    notificationRegistry.finish(
                        id: id,
                        throwing: BLEError.notificationFailed(
                            characteristic.uuid,
                            underlying: String(describing: error)
                        )
                    )
                }
            } else if notificationRegistry.hasSubscribers(for: id) {
                notificationRegistry.yield(data ?? Data(), for: id)
            }

        case let .valueWritten(characteristic, _):
            let id = GATTCharacteristicID(
                serviceUUID: characteristic.serviceUUID,
                characteristicUUID: characteristic.uuid
            )
            operationCoordinator.resolve(key: .write(id), event: event)

        case let .notificationStateUpdated(characteristic, _):
            let id = GATTCharacteristicID(
                serviceUUID: characteristic.serviceUUID,
                characteristicUUID: characteristic.uuid
            )
            operationCoordinator.resolve(
                key: .notificationSetup(id),
                event: event
            )

        case .readyToWriteWithoutResponse:
            operationCoordinator.resolve(
                key: .writeWithoutResponseReady,
                event: event
            )
        }
    }

    func restoreNotifications(options: GATTOperationOptions) async throws {
        for id in notificationRegistry.activeIDs() {
            try await operationQueue.run {
                let characteristic = try await self.resolveCharacteristic(
                    id.characteristicUUID,
                    service: id.serviceUUID,
                    options: options
                )
                try await self.setNotifications(
                    true,
                    characteristic: characteristic,
                    id: id,
                    options: options
                )
                self.notificationRegistry.update(
                    characteristic: characteristic,
                    for: id
                )
            }
        }
    }

    private func resolveCharacteristic(
        _ characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        options: GATTOperationOptions,
        discoveryMode: GATTDiscoveryMode = .targeted
    ) async throws -> CharacteristicRepresenting {
        if discoveryMode == .all {
            return try await resolveCharacteristicByDiscoveringAll(
                characteristicUUID,
                service: serviceUUID,
                options: options
            )
        }

        if let cached = characteristicCache.characteristic(
            characteristicUUID,
            service: serviceUUID
        ) {
            return cached
        }

        emit(.discoveringServices)
        let service = try await resolveService(serviceUUID, options: options)
        let event = try await operationCoordinator.perform(
            key: .characteristicDiscovery(serviceUUID: serviceUUID),
            timeout: options.timeout
        ) {
            self.peripheral.discoverCharacteristics(
                [characteristicUUID],
                for: service
            )
        }

        guard case let .characteristicsDiscovered(
            discoveredService,
            characteristics,
            error
        ) = event,
        discoveredService.uuid == serviceUUID else {
            throw BLEError.characteristicNotFound(
                characteristicUUID,
                service: serviceUUID
            )
        }
        if error != nil {
            throw BLEError.characteristicNotFound(
                characteristicUUID,
                service: serviceUUID
            )
        }

        characteristicCache.store(
            characteristics: characteristics,
            serviceUUID: serviceUUID
        )
        guard let characteristic = characteristicCache.characteristic(
            characteristicUUID,
            service: serviceUUID
        ) else {
            throw BLEError.characteristicNotFound(
                characteristicUUID,
                service: serviceUUID
            )
        }
        emit(.ready)
        return characteristic
    }

    private func resolveCharacteristicByDiscoveringAll(
        _ characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        options: GATTOperationOptions
    ) async throws -> CharacteristicRepresenting {
        emit(.discoveringServices)

        let serviceEvent = try await operationCoordinator.perform(
            key: .serviceDiscovery,
            timeout: options.timeout
        ) {
            self.peripheral.discoverServices(nil)
        }

        guard case let .servicesDiscovered(services, serviceError) = serviceEvent,
              serviceError == nil,
              let service = services.first(where: { $0.uuid == serviceUUID })
        else {
            throw BLEError.serviceNotFound(serviceUUID)
        }
        characteristicCache.store(services: services)

        let characteristicEvent = try await operationCoordinator.perform(
            key: .characteristicDiscovery(serviceUUID: serviceUUID),
            timeout: options.timeout
        ) {
            self.peripheral.discoverCharacteristics(nil, for: service)
        }

        guard case let .characteristicsDiscovered(
            discoveredService,
            characteristics,
            characteristicError
        ) = characteristicEvent,
        characteristicError == nil,
        discoveredService.uuid == serviceUUID
        else {
            throw BLEError.characteristicNotFound(
                characteristicUUID,
                service: serviceUUID
            )
        }

        characteristicCache.store(
            characteristics: characteristics,
            serviceUUID: serviceUUID
        )
        guard let characteristic = characteristics.first(where: {
            $0.uuid == characteristicUUID
        }) else {
            throw BLEError.characteristicNotFound(
                characteristicUUID,
                service: serviceUUID
            )
        }

        emit(.ready)
        return characteristic
    }

    private func resolveService(
        _ serviceUUID: CBUUID,
        options: GATTOperationOptions
    ) async throws -> ServiceRepresenting {
        if let cached = characteristicCache.service(for: serviceUUID) {
            return cached
        }

        let event = try await operationCoordinator.perform(
            key: .serviceDiscovery,
            timeout: options.timeout
        ) {
            self.peripheral.discoverServices([serviceUUID])
        }

        guard case let .servicesDiscovered(services, error) = event,
              error == nil else {
            throw BLEError.serviceNotFound(serviceUUID)
        }
        characteristicCache.store(services: services)
        guard let service = characteristicCache.service(for: serviceUUID) else {
            throw BLEError.serviceNotFound(serviceUUID)
        }
        return service
    }

    private func validateWriteSupport(
        _ characteristic: CharacteristicRepresenting,
        characteristicUUID: CBUUID,
        type: CBCharacteristicWriteType
    ) throws {
        let requiredProperty: CBCharacteristicProperties = type == .withResponse
            ? .write
            : .writeWithoutResponse
        guard characteristic.properties.contains(requiredProperty) else {
            throw BLEError.unsupportedCharacteristicOperation(
                characteristicUUID,
                operation: .write
            )
        }
    }

    private func waitUntilReadyToWriteWithoutResponse(
        options: GATTOperationOptions
    ) async throws {
        guard !peripheral.canSendWriteWithoutResponse else {
            return
        }

        _ = try await operationCoordinator.perform(
            key: .writeWithoutResponseReady,
            timeout: options.timeout
        ) {}
    }

    private func setNotifications(
        _ enabled: Bool,
        characteristic: CharacteristicRepresenting,
        id: GATTCharacteristicID,
        options: GATTOperationOptions
    ) async throws {
        let event = try await operationCoordinator.perform(
            key: .notificationSetup(id),
            timeout: options.timeout
        ) {
            self.peripheral.setNotifyValue(enabled, for: characteristic)
        }

        guard case let .notificationStateUpdated(_, error) = event else {
            throw BLEError.notificationSetupFailed(
                id.characteristicUUID,
                underlying: nil
            )
        }
        if let error {
            throw BLEError.notificationSetupFailed(
                id.characteristicUUID,
                underlying: String(describing: error)
            )
        }
    }

    private func notificationTerminated(
        subscriberID: UUID,
        id: GATTCharacteristicID,
        options: GATTOperationOptions
    ) {
        guard let characteristic = notificationRegistry.remove(
            subscriberID: subscriberID,
            from: id
        ) else {
            return
        }

        Task { [weak self] in
            guard let self, self.isConnected else { return }
            try? await self.operationQueue.run {
                guard !self.notificationRegistry.hasSubscribers(for: id) else {
                    return
                }
                try await self.setNotifications(
                    false,
                    characteristic: characteristic,
                    id: id,
                    options: options
                )
            }
        }
    }
}
