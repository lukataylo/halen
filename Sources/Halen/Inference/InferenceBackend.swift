import Foundation

/// A concrete inference provider behind `RouterInferenceClient`. Each backend
/// reports what it can serve and whether it's currently usable; the router
/// picks one per request and falls through to the next on failure.
protocol InferenceBackend: Sendable {
    var kind: BackendKind { get }
    var capability: BackendCapability { get }

    /// A light probe — may do I/O (e.g. ping a daemon, check OS availability).
    /// The router caches the result briefly so this isn't hit on every keystroke.
    func availability() async -> BackendAvailability

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse

    /// Streaming completion — see `InferenceClient.stream(_:)`. Yields the
    /// cumulative text so far. Backends that can stream tokens (llama.cpp,
    /// Apple FM) override this; everything else gets the default below.
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error>
}

extension InferenceBackend {
    /// Default streaming: a backend with no native token callback simply runs
    /// `complete` and emits the whole result as one final snapshot. The
    /// consumer's streaming code path still works — it just sees a single
    /// update instead of many.
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(response.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum BackendKind: String, Sendable, Codable, CaseIterable {
    case bundledLlama          = "bundled-llama"
    case appleFoundationModels = "apple-fm"
    case ollama                = "ollama"
    case mlx                   = "mlx"

    var displayName: String {
        switch self {
        case .bundledLlama:          return "Built-in (Gemma 4 E4B)"
        case .appleFoundationModels: return "Apple Intelligence"
        case .ollama:                return "Ollama"
        case .mlx:                   return "MLX (Apple Silicon)"
        }
    }
}

struct BackendCapability: Sendable {
    /// Tiers this backend can serve at all. The router filters on this first.
    let servesTiers: Set<ModelTier>
    /// Task kinds this backend is good at — the router nudges toward a match.
    let strongAt: Set<InferenceTaskKind>
    /// Tie-breaker when user preference is equal. Lower = preferred.
    let basePriority: Int
}

enum BackendAvailability: Sendable, Equatable {
    case available
    /// Human-readable reason, surfaced in Settings (e.g. "Ollama not reachable").
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
