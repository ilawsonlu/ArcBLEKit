#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

struct GATTCharacteristicID: Hashable {
    let serviceUUID: CBUUID
    let characteristicUUID: CBUUID
}

struct GATTOperationKey: Hashable {
    let operation: GATTOperation
    let serviceUUID: CBUUID?
    let characteristicUUID: CBUUID?

    static let serviceDiscovery = GATTOperationKey(
        operation: .serviceDiscovery,
        serviceUUID: nil,
        characteristicUUID: nil
    )

    static let writeWithoutResponseReady = GATTOperationKey(
        operation: .writeWithoutResponseReady,
        serviceUUID: nil,
        characteristicUUID: nil
    )

    static func characteristicDiscovery(serviceUUID: CBUUID) -> GATTOperationKey {
        GATTOperationKey(
            operation: .characteristicDiscovery,
            serviceUUID: serviceUUID,
            characteristicUUID: nil
        )
    }

    static func read(_ id: GATTCharacteristicID) -> GATTOperationKey {
        attributeOperation(.read, id: id)
    }

    static func write(_ id: GATTCharacteristicID) -> GATTOperationKey {
        attributeOperation(.write, id: id)
    }

    static func notificationSetup(_ id: GATTCharacteristicID) -> GATTOperationKey {
        attributeOperation(.notificationSetup, id: id)
    }

    private static func attributeOperation(
        _ operation: GATTOperation,
        id: GATTCharacteristicID
    ) -> GATTOperationKey {
        GATTOperationKey(
            operation: operation,
            serviceUUID: id.serviceUUID,
            characteristicUUID: id.characteristicUUID
        )
    }
}

final class GATTOperationCoordinator: @unchecked Sendable {
    private struct PendingOperation {
        let id: UUID
        let continuation: CheckedContinuation<PeripheralEvent, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var pendingOperations: [GATTOperationKey: PendingOperation] = [:]

    func perform(
        key: GATTOperationKey,
        timeout: TimeInterval,
        start: @escaping () -> Void
    ) async throws -> PeripheralEvent {
        guard let timeoutNanoseconds = Self.timeoutNanoseconds(timeout) else {
            throw timeoutError(for: key)
        }

        let operationID = UUID()
        let cancellation = CancellationHandlerBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = PendingOperation(
                    id: operationID,
                    continuation: continuation,
                    timeoutTask: nil
                )

                lock.lock()
                guard pendingOperations[key] == nil else {
                    lock.unlock()
                    continuation.resume(
                        throwing: BLEError.gattOperationInProgress(key.operation)
                    )
                    return
                }
                pendingOperations[key] = pending
                lock.unlock()

                cancellation.set { [weak self] in
                    self?.complete(
                        key: key,
                        id: operationID,
                        result: .failure(BLEError.operationCancelled)
                    )
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.complete(
                        key: key,
                        id: operationID,
                        result: .failure(self.timeoutError(for: key))
                    )
                }
                installTimeoutTask(timeoutTask, key: key, id: operationID)

                guard isPending(key: key, id: operationID) else {
                    return
                }
                start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    @discardableResult
    func resolve(key: GATTOperationKey, event: PeripheralEvent) -> Bool {
        complete(key: key, id: nil, result: .success(event))
    }

    func failAll(with error: Error) {
        lock.lock()
        let pending = Array(pendingOperations.values)
        pendingOperations.removeAll()
        lock.unlock()

        for operation in pending {
            operation.timeoutTask?.cancel()
            operation.continuation.resume(throwing: error)
        }
    }

    private func installTimeoutTask(
        _ task: Task<Void, Never>,
        key: GATTOperationKey,
        id: UUID
    ) {
        lock.lock()
        guard var pending = pendingOperations[key], pending.id == id else {
            lock.unlock()
            task.cancel()
            return
        }
        pending.timeoutTask = task
        pendingOperations[key] = pending
        lock.unlock()
    }

    private func isPending(key: GATTOperationKey, id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingOperations[key]?.id == id
    }

    @discardableResult
    private func complete(
        key: GATTOperationKey,
        id: UUID?,
        result: Result<PeripheralEvent, Error>
    ) -> Bool {
        lock.lock()
        guard let pending = pendingOperations[key],
              id == nil || pending.id == id else {
            lock.unlock()
            return false
        }
        pendingOperations[key] = nil
        lock.unlock()

        pending.timeoutTask?.cancel()
        pending.continuation.resume(with: result)
        return true
    }

    private func timeoutError(for key: GATTOperationKey) -> BLEError {
        .gattOperationTimedOut(
            key.operation,
            service: key.serviceUUID,
            characteristic: key.characteristicUUID
        )
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64? {
        guard timeout.isFinite, timeout > 0 else {
            return nil
        }

        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds)
    }
}
