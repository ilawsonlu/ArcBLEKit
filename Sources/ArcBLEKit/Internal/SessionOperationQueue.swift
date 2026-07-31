import Foundation

actor SessionOperationQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentID: UUID?
    private var waiters: [Waiter] = []

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        let id = UUID()
        try await acquire(id: id)

        do {
            try Task.checkCancellation()
            let value = try await operation()
            release(id: id)
            return value
        } catch is CancellationError {
            release(id: id)
            throw BLEError.operationCancelled
        } catch {
            release(id: id)
            throw error
        }
    }

    func cancelAll(with error: Error) {
        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func acquire(id: UUID) async throws {
        if currentID == nil {
            currentID = id
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    private func release(id: UUID) {
        guard currentID == id else {
            return
        }

        guard !waiters.isEmpty else {
            currentID = nil
            return
        }

        let next = waiters.removeFirst()
        currentID = next.id
        next.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: BLEError.operationCancelled)
    }
}
