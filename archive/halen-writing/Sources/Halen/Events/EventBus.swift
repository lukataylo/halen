import Foundation

/// In-process pub/sub. Multiple subscribers each receive every published event via
/// an `AsyncStream<Event>`. Termination of a stream auto-unsubscribes.
///
/// In M4 this is replaced by JSON-RPC notifications to plugin processes, but the
/// publish/subscribe contract stays the same shape.
final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    /// Per-subscriber drop counter. Slow subscribers — usually because a
    /// plugin task is awaiting Gemma — silently dropped the oldest event in
    /// their buffer before this. Now we count drops and surface them at
    /// exponential thresholds so a sustained-slow consumer leaves an audit
    /// trail without the log being flooded.
    private var dropCounts: [UUID: Int] = [:]

    func subscribe() -> AsyncStream<Event> {
        // Bounded buffer: a slow subscriber drops the oldest events rather than
        // growing memory without limit (caret.moved fires on every keystroke;
        // text.pause can carry several KB of text).
        AsyncStream(Event.self, bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            dropCounts[id] = 0
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.dropCounts.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func publish(_ event: Event) {
        lock.lock()
        // Snapshot keyed pairs so the `.dropped` accounting can attribute
        // the drop to the right subscriber — `Array(continuations.values)`
        // would lose the ID.
        let snapshot = continuations.map { ($0.key, $0.value) }
        lock.unlock()
        for (id, continuation) in snapshot {
            let result = continuation.yield(event)
            if case .dropped = result {
                noteDropForSubscriber(id)
            }
        }
    }

    /// Drop count across every active subscriber. Exposed for tests pinning
    /// that the back-pressure path is wired correctly — production code
    /// reads dropped-event signal off the log warnings, not this property.
    var totalDrops: Int {
        lock.lock(); defer { lock.unlock() }
        return dropCounts.values.reduce(0, +)
    }

    private func noteDropForSubscriber(_ id: UUID) {
        lock.lock()
        let newCount = (dropCounts[id] ?? 0) + 1
        dropCounts[id] = newCount
        lock.unlock()
        // Warn at 1, 10, 100, 1000, then every 1000 thereafter. A healthy run
        // sees zero of these; a sustained-slow subscriber gets O(log N) log
        // lines instead of one per drop (which would itself be a perf hazard).
        let shouldWarn: Bool = {
            switch newCount {
            case 1, 10, 100, 1000: return true
            default: return newCount > 1000 && newCount % 1000 == 0
            }
        }()
        if shouldWarn {
            Log.warn("EventBus: subscriber \(id.uuidString.prefix(8)) dropped \(newCount) events — slow consumer or buffer overflow")
        }
    }
}
