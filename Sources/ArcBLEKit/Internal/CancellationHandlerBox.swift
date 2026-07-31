import Foundation

final class CancellationHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var cancelled = false

    func set(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }

        self.handler = handler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = handler
        self.handler = nil
        lock.unlock()

        handler?()
    }
}
