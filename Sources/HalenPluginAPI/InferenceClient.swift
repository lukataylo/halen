import Foundation

/// Hint about what kind of work a request is. The router uses it to prefer a
/// backend that's good at the task — e.g. a small bundled model is fine for
/// `.classification` but weak at `.generation`.
public enum InferenceTaskKind: String, Sendable, Codable {
    case classification   // short extractive output: a tone label, a yes/no
    case generation       // rewrites, summaries, briefings — needs a capable model
}

/// Who is waiting on this request. The host runs one inference queue; when a
/// model is contended, higher-priority waiters always run first. This is how
/// a background plugin is prevented from stealing latency from a foreground
/// one — declare honestly.
public enum InferencePriority: Int, Sendable, Codable, Comparable {
    /// Nobody is looking: periodic classification, ambient analysis.
    case background = 0
    /// The user did something and is waiting for the result: a hotkey
    /// rewrite, a palette answer, a snippet expansion.
    case userInitiated = 1

    public static func < (lhs: InferencePriority, rhs: InferencePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct InferenceRequest: Sendable {
    public let prompt: String
    public let tier: ModelTier
    public let maxTokens: Int
    public let temperature: Double
    public let stop: [String]
    /// Defaults to `.generation` — the conservative choice, so the router only
    /// down-routes to a weak model when a caller explicitly opts into it.
    public let taskKind: InferenceTaskKind
    /// Defaults to `.userInitiated` — the conservative choice for latency;
    /// ambient/periodic callers must opt *down* to `.background`.
    public let priority: InferencePriority

    public init(prompt: String,
                tier: ModelTier,
                maxTokens: Int = 256,
                temperature: Double = 0.2,
                stop: [String] = [],
                taskKind: InferenceTaskKind = .generation,
                priority: InferencePriority = .userInitiated) {
        self.prompt = prompt
        self.tier = tier
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stop = stop
        self.taskKind = taskKind
        self.priority = priority
    }
}

public struct InferenceResponse: Sendable {
    public let text: String
    public let modelId: String
    public let latencyMs: Int

    public init(text: String, modelId: String, latencyMs: Int) {
        self.text = text
        self.modelId = modelId
        self.latencyMs = latencyMs
    }
}

public protocol InferenceClient: Sendable {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse

    /// Streaming variant of `complete`. Each yielded value is the **cumulative**
    /// completion text generated so far — not a delta. Yielding snapshots (vs
    /// deltas) lets a consumer throttle freely and always render the latest
    /// value, and lets the producer correct the tail (e.g. a stop-sequence
    /// truncation) in a later snapshot.
    ///
    /// The stream finishes when generation ends, and throws if generation
    /// fails. Backends with no native token streaming emit the whole
    /// completion as a single final snapshot.
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error>
}
