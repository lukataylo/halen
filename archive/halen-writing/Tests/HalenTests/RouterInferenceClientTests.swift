import XCTest
@testable import Halen

// MARK: - Test double

/// A configurable `InferenceBackend` stand-in. Every observable behaviour the
/// router depends on — declared capability, probed availability, and the
/// `complete()` outcome — is injectable, and `availabilityProbes` / `completeCalls`
/// count actual invocations so the caching tests can assert the router didn't
/// re-probe or re-run when it shouldn't have.
///
/// Backed by an actor purely so the mutable counters and the swappable
/// availability are safe to touch from the router's actor and the test at the
/// same time without tripping the `Sendable` checker.
final class MockInferenceBackend: InferenceBackend, @unchecked Sendable {
    enum CompleteOutcome {
        case succeed(text: String)
        case fail(Error)
        case cancel
    }

    let kind: BackendKind
    let capability: BackendCapability

    private let state = State()

    private actor State {
        var availability: BackendAvailability = .available
        var outcome: CompleteOutcome = .succeed(text: "ok")
        var availabilityProbes = 0
        var completeCalls = 0

        func setAvailability(_ value: BackendAvailability) { availability = value }
        func setOutcome(_ value: CompleteOutcome) { outcome = value }
        func probe() -> BackendAvailability { availabilityProbes += 1; return availability }
        func recordCall() -> CompleteOutcome { completeCalls += 1; return outcome }
    }

    init(kind: BackendKind,
         servesTiers: Set<ModelTier> = [.small, .medium, .large],
         strongAt: Set<InferenceTaskKind> = [],
         basePriority: Int = 0) {
        self.kind = kind
        self.capability = BackendCapability(servesTiers: servesTiers,
                                            strongAt: strongAt,
                                            basePriority: basePriority)
    }

    func availability() async -> BackendAvailability {
        await state.probe()
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        switch await state.recordCall() {
        case .succeed(let text):
            return InferenceResponse(text: text, modelId: kind.rawValue, latencyMs: 1)
        case .fail(let error):
            throw error
        case .cancel:
            throw CancellationError()
        }
    }

    // MARK: Test controls

    func setAvailability(_ value: BackendAvailability) async { await state.setAvailability(value) }
    func setOutcome(_ value: CompleteOutcome) async { await state.setOutcome(value) }
    var availabilityProbes: Int { get async { await state.availabilityProbes } }
    var completeCalls: Int { get async { await state.completeCalls } }
}

/// A distinct error type so a "backend failed" fall-through is unambiguously
/// not a `CancellationError` and not a `RouterError`.
private struct BackendBoom: Error {}

@MainActor
private func makeSettings(order: [BackendKind]) -> InferenceSettings {
    let settings = InferenceSettings()
    settings.preferenceOrder = order
    return settings
}

private func request(tier: ModelTier = .medium,
                     taskKind: InferenceTaskKind = .generation) -> InferenceRequest {
    InferenceRequest(prompt: "hi", tier: tier, taskKind: taskKind)
}

// MARK: - Candidate ordering

/// The router's routing decision is a lexicographic sort: user preference wins,
/// then task-affinity, then the backend's own `basePriority` tie-breaker. Each
/// test isolates one level of that key.
final class RouterCandidateOrderingTests: XCTestCase {
    func testUserPreferenceDominates() async throws {
        // Ollama is last by base priority and not task-strong, but the user put
        // it first — preference must override every later tie-breaker.
        let ollama = MockInferenceBackend(kind: .ollama, basePriority: 99)
        let llama = MockInferenceBackend(kind: .bundledLlama,
                                         strongAt: [.generation],
                                         basePriority: 0)
        let settings = await makeSettings(order: [.ollama, .bundledLlama])
        let router = RouterInferenceClient(backends: [llama, ollama], settings: settings)

        let response = try await router.complete(request())
        XCTAssertEqual(response.modelId, BackendKind.ollama.rawValue)
    }

    func testTaskAffinityBreaksPreferenceTie() async throws {
        // Both backends are absent from `preferenceOrder`, so they share
        // prefIndex == count. The task-strong backend must then win.
        let weak = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let strong = MockInferenceBackend(kind: .ollama,
                                          strongAt: [.classification],
                                          basePriority: 50)
        let settings = await makeSettings(order: [])
        let router = RouterInferenceClient(backends: [weak, strong], settings: settings)

        let response = try await router.complete(request(taskKind: .classification))
        XCTAssertEqual(response.modelId, BackendKind.ollama.rawValue)
    }

    func testBasePriorityBreaksRemainingTie() async throws {
        // Equal preference (neither listed) and equal task-affinity (neither
        // strong at the task) — only `basePriority` is left, lower wins.
        let high = MockInferenceBackend(kind: .ollama, basePriority: 1)
        let low = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let settings = await makeSettings(order: [])
        let router = RouterInferenceClient(backends: [high, low], settings: settings)

        let response = try await router.complete(request())
        XCTAssertEqual(response.modelId, BackendKind.bundledLlama.rawValue)
    }

    func testPreferenceOutranksTaskAffinity() async throws {
        // The non-task-strong backend is preferred; preference sits ahead of
        // task-affinity in the sort key, so it must still be picked first.
        let preferredButWeak = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let unpreferredButStrong = MockInferenceBackend(kind: .ollama,
                                                        strongAt: [.generation],
                                                        basePriority: 0)
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [unpreferredButStrong, preferredButWeak],
                                           settings: settings)

        let response = try await router.complete(request(taskKind: .generation))
        XCTAssertEqual(response.modelId, BackendKind.bundledLlama.rawValue)
    }
}

// MARK: - Fall-through

final class RouterFallthroughTests: XCTestCase {
    func testSkipsUnavailableFirstCandidate() async throws {
        let first = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let second = MockInferenceBackend(kind: .ollama, basePriority: 1)
        await first.setAvailability(.unavailable(reason: "offline"))
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [first, second], settings: settings)

        let response = try await router.complete(request())
        XCTAssertEqual(response.modelId, BackendKind.ollama.rawValue)
        // An unavailable backend is never asked to do work.
        let firstCalls = await first.completeCalls
        XCTAssertEqual(firstCalls, 0)
    }

    func testFallsThroughWhenCompleteThrows() async throws {
        let first = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let second = MockInferenceBackend(kind: .ollama, basePriority: 1)
        await first.setOutcome(.fail(BackendBoom()))
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [first, second], settings: settings)

        let response = try await router.complete(request())
        XCTAssertEqual(response.modelId, BackendKind.ollama.rawValue)
        // The first backend was reached and tried before being skipped.
        let firstCalls = await first.completeCalls
        XCTAssertEqual(firstCalls, 1)
    }

    func testAllBackendsFailingThrowsAllBackendsFailed() async {
        let first = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let second = MockInferenceBackend(kind: .ollama, basePriority: 1)
        await first.setOutcome(.fail(BackendBoom()))
        await second.setOutcome(.fail(BackendBoom()))
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [first, second], settings: settings)

        do {
            _ = try await router.complete(request())
            XCTFail("expected RouterError.allBackendsFailed")
        } catch let RouterError.allBackendsFailed(underlying) {
            // The last backend's error is carried through for the logs.
            XCTAssertTrue(underlying is BackendBoom)
        } catch {
            XCTFail("expected RouterError.allBackendsFailed, got \(error)")
        }
    }

    func testAllUnavailableThrowsAllBackendsFailed() async {
        // Every eligible backend exists but each probes `.unavailable` —
        // the chain is non-empty so this is `allBackendsFailed`, not
        // `noBackendAvailable`.
        let first = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let second = MockInferenceBackend(kind: .ollama, basePriority: 1)
        await first.setAvailability(.unavailable(reason: "x"))
        await second.setAvailability(.unavailable(reason: "y"))
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [first, second], settings: settings)

        do {
            _ = try await router.complete(request())
            XCTFail("expected RouterError.allBackendsFailed")
        } catch let RouterError.allBackendsFailed(underlying) {
            // Last failure recorded was a `.backendUnavailable`, not a real error.
            if case RouterError.backendUnavailable(.ollama)? = underlying {
                // expected
            } else {
                XCTFail("expected .backendUnavailable underlying, got \(String(describing: underlying))")
            }
        } catch {
            XCTFail("expected RouterError.allBackendsFailed, got \(error)")
        }
    }
}

// MARK: - No backend available

final class RouterNoBackendTests: XCTestCase {
    func testNoBackendServesTierThrowsNoBackendAvailable() async {
        // Both backends serve only `.small`; a `.large` request has an empty
        // candidate chain before any availability probing happens.
        let llama = MockInferenceBackend(kind: .bundledLlama, servesTiers: [.small])
        let ollama = MockInferenceBackend(kind: .ollama, servesTiers: [.small])
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [llama, ollama], settings: settings)

        do {
            _ = try await router.complete(request(tier: .large))
            XCTFail("expected RouterError.noBackendAvailable")
        } catch let RouterError.noBackendAvailable(tier) {
            XCTAssertEqual(tier, .large)
        } catch {
            XCTFail("expected RouterError.noBackendAvailable, got \(error)")
        }

        // Empty chain ⇒ the router never probes availability.
        let probes = await llama.availabilityProbes
        XCTAssertEqual(probes, 0)
    }

    func testEmptyBackendSetThrowsNoBackendAvailable() async {
        let settings = await makeSettings(order: [])
        let router = RouterInferenceClient(backends: [], settings: settings)

        do {
            _ = try await router.complete(request())
            XCTFail("expected RouterError.noBackendAvailable")
        } catch let RouterError.noBackendAvailable(tier) {
            XCTAssertEqual(tier, .medium)
        } catch {
            XCTFail("expected RouterError.noBackendAvailable, got \(error)")
        }
    }
}

// MARK: - Availability TTL caching

/// The TTLs themselves (15 s / 60 s) are far longer than a test run, so an
/// `.available` result is exercised purely through "stays cached" and an
/// `.unavailable` result through "stays cached" — both within the same run —
/// and `refreshAvailability()` is the lever that forces a re-probe.
final class RouterAvailabilityCacheTests: XCTestCase {
    func testAvailableResultIsNotReProbedWithinTTL() async throws {
        let backend = MockInferenceBackend(kind: .bundledLlama)
        let settings = await makeSettings(order: [.bundledLlama])
        let router = RouterInferenceClient(backends: [backend], settings: settings)

        _ = try await router.complete(request())
        _ = try await router.complete(request())
        _ = try await router.complete(request())

        // First call probes once; the 15 s available-TTL means the next two
        // ride the cache.
        let probes = await backend.availabilityProbes
        XCTAssertEqual(probes, 1)
    }

    func testUnavailableResultIsNotReProbedWithinTTL() async {
        // A single unavailable backend: each `complete()` fails, but the
        // 60 s unavailable-TTL means the backend is probed exactly once
        // across repeated requests.
        let backend = MockInferenceBackend(kind: .bundledLlama)
        await backend.setAvailability(.unavailable(reason: "down"))
        let settings = await makeSettings(order: [.bundledLlama])
        let router = RouterInferenceClient(backends: [backend], settings: settings)

        for _ in 0..<3 {
            _ = try? await router.complete(request())
        }

        let probes = await backend.availabilityProbes
        XCTAssertEqual(probes, 1)
    }

    func testRefreshAvailabilityClearsCacheAndReProbes() async throws {
        let backend = MockInferenceBackend(kind: .bundledLlama)
        let settings = await makeSettings(order: [.bundledLlama])
        let router = RouterInferenceClient(backends: [backend], settings: settings)

        _ = try await router.complete(request())
        let afterFirst = await backend.availabilityProbes
        XCTAssertEqual(afterFirst, 1)

        // Refresh wipes the cache and probes every backend immediately.
        await router.refreshAvailability()
        let afterRefresh = await backend.availabilityProbes
        XCTAssertEqual(afterRefresh, 2)

        // The post-refresh result is itself cached again.
        _ = try await router.complete(request())
        let afterThirdRequest = await backend.availabilityProbes
        XCTAssertEqual(afterThirdRequest, 2)
    }

    func testBackendFailureInvalidatesAvailabilityCache() async throws {
        // When `complete()` throws, the router drops that backend's cached
        // availability so the next request re-probes rather than trusting a
        // possibly-stale `.available`.
        let backend = MockInferenceBackend(kind: .bundledLlama)
        await backend.setOutcome(.fail(BackendBoom()))
        let settings = await makeSettings(order: [.bundledLlama])
        let router = RouterInferenceClient(backends: [backend], settings: settings)

        _ = try? await router.complete(request())   // probe #1, then fails
        _ = try? await router.complete(request())   // cache was cleared ⇒ probe #2

        let probes = await backend.availabilityProbes
        XCTAssertEqual(probes, 2)
    }
}

// MARK: - Cancellation

final class RouterCancellationTests: XCTestCase {
    func testCancellationErrorFromBackendIsRethrownAsCancellation() async {
        // A backend that throws `CancellationError` represents a cancelled
        // plugin, not a backend fault — it must surface as cancellation and
        // must NOT fall through to the next backend.
        let first = MockInferenceBackend(kind: .bundledLlama, basePriority: 0)
        let second = MockInferenceBackend(kind: .ollama, basePriority: 1)
        await first.setOutcome(.cancel)
        let settings = await makeSettings(order: [.bundledLlama, .ollama])
        let router = RouterInferenceClient(backends: [first, second], settings: settings)

        do {
            _ = try await router.complete(request())
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // The fall-through backend must never have been consulted.
        let secondCalls = await second.completeCalls
        XCTAssertEqual(secondCalls, 0)
    }
}

// MARK: - AsyncSemaphore

final class AsyncSemaphoreTests: XCTestCase {
    func testUncontendedWaitDoesNotBlock() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()   // permit available — returns immediately
        await sem.signal()
    }

    func testSerializesContendingWaiters() async throws {
        // value == 1 ⇒ at most one holder at a time. Two tasks contend; the
        // observed maximum concurrency must never exceed 1.
        let sem = AsyncSemaphore(value: 1)
        let counter = ConcurrencyCounter()

        @Sendable func critical() async throws {
            try await sem.wait()
            await counter.enter()
            // Yield a few times so a broken semaphore would interleave here.
            for _ in 0..<5 { await Task.yield() }
            await counter.leave()
            await sem.signal()
        }

        async let a: Void = critical()
        async let b: Void = critical()
        _ = try await (a, b)

        let peak = await counter.peak
        XCTAssertEqual(peak, 1)
    }

    func testCancellingAParkedWaiterThrowsAndFreesTheQueue() async throws {
        // One task holds the only permit; a second parks behind it; a third
        // would park too. Cancelling the parked task must throw
        // `CancellationError` for it without consuming the permit, so once
        // the holder signals the queue drains cleanly.
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()   // test holds the permit

        let parked = Task { try await sem.wait() }
        // Give the parked task a moment to actually enqueue itself.
        for _ in 0..<10 { await Task.yield() }

        parked.cancel()
        do {
            try await parked.value
            XCTFail("expected the parked waiter to throw CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // The permit was never handed to the cancelled waiter — signalling it
        // back makes it available, and a fresh wait must succeed promptly.
        await sem.signal()
        try await sem.wait()
        await sem.signal()
    }

    func testWaitOnAlreadyCancelledTaskThrowsWithoutTakingPermit() async throws {
        // value == 0 forces the parking path; the task is cancelled before it
        // runs, so `wait()` must throw without ever enqueueing a continuation.
        let sem = AsyncSemaphore(value: 0)
        let task = Task { try await sem.wait() }
        task.cancel()

        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // No continuation leaked: signalling raises the count to 1, which the
        // next waiter consumes immediately.
        await sem.signal()
        try await sem.wait()
    }
}

/// Tracks how many tasks are simultaneously inside a critical section so a
/// concurrency test can assert a hard ceiling.
private actor ConcurrencyCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}
