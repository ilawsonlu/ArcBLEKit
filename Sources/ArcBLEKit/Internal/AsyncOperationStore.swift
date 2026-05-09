import Foundation

actor AsyncOperationStore<Key: Hashable, Value> {
    private var continuations: [Key: CheckedContinuation<Value, Error>] = [:]

    func store(_ continuation: CheckedContinuation<Value, Error>, for key: Key) {
        continuations[key] = continuation
    }

    func resume(key: Key, returning value: Value) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(returning: value)
    }

    func resume(key: Key, throwing error: Error) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(throwing: error)
    }
}
