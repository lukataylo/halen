import Foundation

/// Routes each `InferenceRequest` to the best available backend, falling through
/// the candidate chain on failure. Drops in behind the `InferenceClient` protocol
/// at `AppCoordinator`, so plugins see no change.
///
/// Concurrency: per-backend `AsyncSemaphore(1)` serializes same-backend requests
/// (two plugins hammering one Ollama daemon was causing 15s+ collisions) while
/// different backends still run in parallel.
actor RouterInferenceClient: InferenceClient {
    private let backends: [InferenceBackend]
    private let settings: InferenceSettings
    private let gates: [BackendKind: AsyncSemaphore]

    private var availabilityCache: [BackendKind: (value: BackendAvailability, at: Date)] = [:]
    /// `.available` results re-probe quickly so a backend coming online is picked
    /// up promptly. `.unavailable` results sit much longer — re-probing a missing
    /// Ollama daemon every 15 s burns a network round-trip for nothing, and the
    /// user can force a refresh from the Settings backend picker.
    private let availabilityTTLAvailable: TimeInterval = 15
    private let availabilityTTLUnavailable: TimeInterval = 60

    init(backends: [InferenceBackend], settings: InferenceSettings) {
        self.backends = backends
        self.settings = settings
        var gates: [BackendKind: AsyncSemaphore] = [:]
        for backend in backends {
            gates[backend.kind] = AsyncSemaphore(value: 1)
        }
        self.gates = gates
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let chain = await orderedCandidates(for: request)
        guard !chain.isEmpty else { throw RouterError.noBackendAvailable(request.tier) }

        var lastError: Error?
        for backend in chain {
            let availability = await cachedAvailability(backend)
            guard availability.isAvailable else {
                lastError = RouterError.backendUnavailable(backend.kind)
                continue
            }
            do {
                return try await run(request, on: backend)
            } catch is CancellationError {
                throw CancellationError()   // a cancelled plugin isn't a backend failure
            } catch {
                lastError = error
                availabilityCache[backend.kind] = nil   // re-probe before trusting it again
                Log.warn("Router: \(backend.kind.rawValue) failed (\(error)) — trying next backend")
                continue
            }
        }
        throw RouterError.allBackendsFailed(lastError)
    }

    /// Clear the availability cache and re-probe every backend now. Called by the
    /// Settings backend picker's Refresh button and its periodic poll.
    ///
    /// As a side benefit: any backend that flipped from `.unavailable` to
    /// `.available` (Apple Intelligence finishing its initial model download,
    /// Ollama daemon being started) is prewarmed here so the first inference
    /// after the flip doesn't pay the cold-start tax.
    func refreshAvailability() async {
        let previous = availabilityCache.mapValues(\.value)
        availabilityCache.removeAll()
        for backend in backends {
            let now = await cachedAvailability(backend)
            let wasAvailable = previous[backend.kind]?.isAvailable ?? false
            if !wasAvailable && now.isAvailable {
                await InferenceBackends.prewarmAll([backend])
            }
        }
    }

    // MARK: - Routing

    private func orderedCandidates(for request: InferenceRequest) async -> [InferenceBackend] {
        let preference = await settings.preferenceOrder
        let eligible = backends.filter { $0.capability.servesTiers.contains(request.tier) }

        // Lexicographic sort key (user preference, task-affinity, base priority) —
        // no magic-number bands; preference always wins, then task fit, then the
        // backend's own tie-breaker.
        func sortKey(_ backend: InferenceBackend) -> (Int, Int, Int) {
            let prefIndex = preference.firstIndex(of: backend.kind) ?? preference.count
            let taskMismatch = backend.capability.strongAt.contains(request.taskKind) ? 0 : 1
            return (prefIndex, taskMismatch, backend.capability.basePriority)
        }
        return eligible.sorted { sortKey($0) < sortKey($1) }
    }

    private func run(_ request: InferenceRequest, on backend: InferenceBackend) async throws -> InferenceResponse {
        let gate = gates[backend.kind]!
        // Throws `CancellationError` if cancelled while queued — no permit was
        // acquired in that case, so there is nothing to release.
        try await gate.wait()
        do {
            try Task.checkCancellation()   // cancelled after acquiring? bail before working
            let response = try await backend.complete(request)
            await gate.signal()
            return response
        } catch {
            await gate.signal()
            throw error
        }
    }

    private func cachedAvailability(_ backend: InferenceBackend) async -> BackendAvailability {
        if let cached = availabilityCache[backend.kind] {
            let ttl = cached.value.isAvailable ? availabilityTTLAvailable : availabilityTTLUnavailable
            if Date().timeIntervalSince(cached.at) < ttl {
                return cached.value
            }
        }
        let value = await backend.availability()
        availabilityCache[backend.kind] = (value, Date())
        // Log every fresh probe — surfaces exactly what each backend reports
        // (e.g. Apple Intelligence's specific UnavailableReason) so a user
        // saying "I enabled it but Halen doesn't see it" can be diagnosed
        // from the log without re-instrumenting.
        Log.info("Router: \(backend.kind.rawValue) availability = \(value)")
        let settings = self.settings
        let kind = backend.kind
        await MainActor.run { settings.availability[kind] = value }
        return value
    }
}

enum RouterError: Error, LocalizedError, CustomStringConvertible {
    case noBackendAvailable(ModelTier)
    case backendUnavailable(BackendKind)
    case allBackendsFailed(Error?)

    /// User-facing — surfaced in plugin UIs (e.g. Meeting Prep) via
    /// `error.localizedDescription`. Kept actionable, never a raw error dump.
    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No AI backend is available. Open Halen Settings to check the built-in model, or start Ollama."
        case .backendUnavailable(let kind):
            return "\(kind.displayName) is currently unavailable."
        case .allBackendsFailed:
            return "Halen couldn't reach any AI backend. The built-in model may have failed to load — open Settings to check."
        }
    }

    /// Technical detail for logs (`Log.warn`), including the underlying error.
    var description: String {
        switch self {
        case .noBackendAvailable(let tier):
            return "No inference backend can serve the \(tier.rawValue) tier"
        case .backendUnavailable(let kind):
            return "Backend \(kind.displayName) is unavailable"
        case .allBackendsFailed(let underlying):
            return "All inference backends failed" + (underlying.map { ": \($0)" } ?? "")
        }
    }
}
