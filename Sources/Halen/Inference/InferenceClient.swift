import Foundation

/// Hint about what kind of work a request is. The router uses it to prefer a
/// backend that's good at the task — e.g. a small bundled model is fine for
/// `.classification` but weak at `.generation`.
enum InferenceTaskKind: String, Sendable, Codable {
    case classification   // short extractive output: a tone label, a yes/no
    case generation       // rewrites, summaries, briefings — needs a capable model
}

struct InferenceRequest: Sendable {
    var prompt: String
    var tier: ModelTier
    var maxTokens: Int = 256
    var temperature: Double = 0.2
    var stop: [String] = []
    /// Defaults to `.generation` — the conservative choice, so the router only
    /// down-routes to a weak model when a caller explicitly opts into it.
    var taskKind: InferenceTaskKind = .generation
}

struct InferenceResponse: Sendable {
    var text: String
    var modelId: String
    var latencyMs: Int
}

protocol InferenceClient: Sendable {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse
}
