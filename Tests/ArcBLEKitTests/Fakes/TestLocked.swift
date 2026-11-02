import Foundation

/// Synchronizes fake state shared by test tasks and simulated delegate callbacks.
/// `_modify` keeps read-modify-write operations such as Array.append under one lock.
@propertyWrapper
final class TestLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &value
        }
    }
}
