import Foundation
import HalenPluginAPI

/// Minimal async counting semaphore with priority-ordered waiters. Used by
/// `RouterInferenceClient` to serialize requests per backend without blocking
/// a thread inside `await` (which a `DispatchSemaphore` would do).
///
/// This is the platform's "single inference queue with priorities": when a
/// model is contended, `.userInitiated` waiters always acquire before
/// `.background` ones, FIFO within the same priority. There is deliberately
/// no preemption of an in-flight generation — a foreground request waits at
/// most one background generation, which keeps the model runtime simple.
///
/// `wait()` is cancellation-aware: a request whose `Task` is cancelled while
/// queued is removed from the waiter list and `wait()` throws `CancellationError`,
/// so it never leaks a continuation or holds a permit it didn't acquire.
actor AsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let priority: InferencePriority
        /// Monotonic arrival stamp — FIFO tiebreak within a priority band.
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var value: Int
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0

    init(value: Int) {
        self.value = value
    }

    func wait(priority: InferencePriority = .userInitiated) async throws {
        if value > 0 {
            value -= 1
            return
        }
        let id = UUID()
        let sequence = nextSequence
        nextSequence &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Already cancelled before we parked — don't enqueue at all.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, priority: priority,
                                          sequence: sequence, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        guard !waiters.isEmpty else {
            value += 1
            return
        }
        // Highest priority first; FIFO (lowest sequence) within a band.
        // Linear scan — the queue is a handful of plugins deep at worst.
        var best = 0
        for i in waiters.indices.dropFirst() {
            let candidate = waiters[i]
            let leader = waiters[best]
            if candidate.priority > leader.priority
                || (candidate.priority == leader.priority && candidate.sequence < leader.sequence) {
                best = i
            }
        }
        waiters.remove(at: best).continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
