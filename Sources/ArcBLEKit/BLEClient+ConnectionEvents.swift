import Foundation

public extension BLEClient {
    /// Observes future system peer events matching any supplied service or identifier.
    ///
    /// One event stream is active per client. Starting another finishes the previous stream.
    /// Cancel the consuming task or release the client to clear registration. Bluetooth must initially be ready;
    /// matching is registered again after Bluetooth powers back on. Use
    /// `retrieveConnectedDevices(withServices:)` to query peers connected before registration.
    /// A connected event does not establish a GATT session or confirm audio readiness.
    @available(macOS, unavailable, message: "CoreBluetooth connection events are unavailable on macOS")
    func connectionEvents(matching filter: ConnectionEventFilter) -> AsyncThrowingStream<ConnectionEvent, Error> {
        makeConnectionEvents(matching: filter)
    }
}

extension BLEClient {
    func makeConnectionEvents(matching filter: ConnectionEventFilter) -> AsyncThrowingStream<ConnectionEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                try validateBluetoothReady()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let matchesNothing = filter.serviceUUIDs.isEmpty && filter.peripheralIdentifiers.isEmpty
            let id = UUID()
            eventRegistrationLock.lock()
            eventLock.lock()
            let previous = eventContinuation
            eventID = id
            eventFilter = matchesNothing ? nil : filter
            eventContinuation = continuation
            eventLock.unlock()
            central.registerForConnectionEvents(matching: matchesNothing ? nil : filter)
            eventRegistrationLock.unlock()
            previous?.finish()
            continuation.onTermination = { [weak self] _ in
                self?.finishConnectionEvents(id: id)
            }
            if matchesNothing { continuation.finish() }
        }
    }

    func publishConnectionEvent(_ kind: ConnectionEvent.Kind, peripheral: PeripheralRepresenting) {
        remember(peripheral)
        eventLock.lock()
        let continuation = eventContinuation
        eventLock.unlock()
        continuation?.yield(ConnectionEvent(kind: kind, device: makeRetrievedDevice(peripheral)))
    }

    func refreshConnectionEventRegistration(state: BluetoothState) {
        guard state == .poweredOn else { return }
        eventRegistrationLock.lock()
        defer { eventRegistrationLock.unlock() }
        eventLock.lock()
        let filter = eventFilter
        eventLock.unlock()
        central.registerForConnectionEvents(matching: filter)
    }

    private func finishConnectionEvents(id: UUID) {
        eventRegistrationLock.lock()
        defer { eventRegistrationLock.unlock() }
        eventLock.lock()
        guard eventID == id else {
            eventLock.unlock()
            return
        }
        eventID = nil
        eventFilter = nil
        eventContinuation = nil
        eventLock.unlock()
        central.registerForConnectionEvents(matching: nil)
    }
}
