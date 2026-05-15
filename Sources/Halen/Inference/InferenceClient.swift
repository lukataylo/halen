import Foundation

/// Hint about what kind of work a request is. The router uses it to prefer a
/// backend that's good at the task — e.g. a small bundled model is fine for
/// `.classification` but weak at `.generation`.
enum InferenceTaskKind: String, Sendable, Codable {
    case classification   // short extractive output: a tone label, a yes/no
    case generation       // rewrites, summaries, briefings — needs a capable model
}

struct InferenceRequest: Sendable {
    let prompt: String
    let tier: ModelTier
    let maxTokens: Int
    let temperature: Double
    let stop: [String]
    /// Defaults to `.generation` — the conservative choice, so the router only
    /// down-routes to a weak model when a caller explicitly opts into it.
    let taskKind: InferenceTaskKind

    init(prompt: String,
         tier: ModelTier,
         maxTokens: Int = 256,
         temperature: Double = 0.2,
         stop: [String] = [],
         taskKind: InferenceTaskKind = .generation) {
        self.prompt = prompt
        self.tier = tier
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stop = stop
        self.taskKind = taskKind
    }
}

struct InferenceResponse: Sendable {
    let text: String
    let modelId: String
    let latencyMs: Int
}

protocol InferenceClient: Sendable {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse
}
