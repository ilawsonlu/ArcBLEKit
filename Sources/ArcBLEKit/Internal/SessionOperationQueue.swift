actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class SessionOperationQueue {
    private let semaphore = AsyncSemaphore(value: 1)

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        await semaphore.wait()

        do {
            let value = try await operation()
            await semaphore.signal()
            return value
        } catch {
            await semaphore.signal()
            throw error
        }
    }
}
