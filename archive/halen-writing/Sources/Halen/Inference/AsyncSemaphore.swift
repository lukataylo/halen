import Foundation

/// Minimal async counting semaphore. Used by `RouterInferenceClient` to serialize
/// requests per backend without blocking a thread inside `await` (which a
/// `DispatchSemaphore` would do).
///
/// `wait()` is cancellation-aware: a request whose `Task` is cancelled while
/// queued is removed from the waiter list and `wait()` throws `CancellationError`,
/// so it never leaks a continuation or holds a permit it didn't acquire.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(value: Int) {
        self.value = value
    }

    func wait() async throws {
        if value > 0 {
            value -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Already cancelled before we parked — don't enqueue at all.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
