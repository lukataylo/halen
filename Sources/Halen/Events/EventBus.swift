import Foundation

/// In-process pub/sub. Multiple subscribers each receive every published event via
/// an `AsyncStream<Event>`. Termination of a stream auto-unsubscribes.
///
/// In M4 this is replaced by JSON-RPC notifications to plugin processes, but the
/// publish/subscribe contract stays the same shape.
final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    func subscribe() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func publish(_ event: Event) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for continuation in snapshot {
            continuation.yield(event)
        }
    }
}
