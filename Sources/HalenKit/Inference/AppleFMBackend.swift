import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model via the Foundation Models framework (macOS 26+).
/// Zero install, zero bundled weight — but gated on Apple-Intelligence-capable
/// hardware and the feature being enabled, so it's an *optional* backend the
/// router falls through when unavailable.
///
/// Serves `.small` and `.medium`; the system model isn't sized for `.large`.
/// Also offered as a `.classifier` fallback for when the dedicated Qwen 0.5B
/// classifier isn't downloaded — Qwen's lower `basePriority` (3 vs 10) keeps
/// it preferred when both are present.
@available(macOS 26, *)
final class AppleFMBackend: InferenceBackend {
    let kind: BackendKind = .appleFoundationModels
    let capability = BackendCapability(
        servesTiers: [.classifier, .small, .medium],
        strongAt: [.classification, .generation],
        basePriority: 10
    )

    func availability() async -> BackendAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "Apple model unavailable")
        }
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let start = Date()
        // Fresh session per request: plugin calls are stateless one-shots, so
        // there's no conversation to preserve and this avoids context growth.
        let session = LanguageModelSession()
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens
        )

        let response: LanguageModelSession.Response<String>
        do {
            response = try await session.respond(to: request.prompt, options: options)
        } catch let err as LanguageModelSession.GenerationError {
            // Map the documented case so the router can decide. Anything else
            // (guardrails, tool errors, future cases) bubbles as a plain throw
            // so the router falls through to llama.cpp.
            switch err {
            case .exceededContextWindowSize:
                throw AppleFMError.contextOverflow
            default:
                throw err
            }
        }

        // Foundation Models has no native stop-sequence param — truncate at the
        // earliest match across all stop tokens (order-independent).
        var text = response.content
        if let earliest = request.stop
            .filter({ !$0.isEmpty })
            .compactMap({ text.range(of: $0)?.lowerBound })
            .min() {
            text = String(text[..<earliest])
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return InferenceResponse(text: text, modelId: "apple-fm/system", latencyMs: latency)
    }

    /// Token-streaming variant of `complete`. The default protocol
    /// implementation runs `complete` once and yields the whole string;
    /// this overrides it so Snippet Expander's `;reply` / rephrase / AI
    /// snippets stream their rewrite live under Apple Intelligence, the
    /// same way they do under bundled Gemma. Stop-sequence handling
    /// mirrors `complete` — Foundation Models has no native stop param,
    /// so we truncate each snapshot at the earliest match.
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = LanguageModelSession()
                let options = GenerationOptions(
                    temperature: request.temperature,
                    maximumResponseTokens: request.maxTokens
                )
                let stops = request.stop.filter { !$0.isEmpty }
                do {
                    let stream = session.streamResponse(to: request.prompt, options: options)
                    for try await snapshot in stream {
                        if Task.isCancelled { return }
                        // `Snapshot.content` is the cumulative text so
                        // far. Apply the same stop-sequence truncation
                        // `complete` does so a downstream consumer never
                        // sees text past the first stop.
                        var text = snapshot.content
                        if let earliest = stops
                            .compactMap({ text.range(of: $0)?.lowerBound })
                            .min() {
                            text = String(text[..<earliest])
                        }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch let err as LanguageModelSession.GenerationError {
                    switch err {
                    case .exceededContextWindowSize:
                        continuation.finish(throwing: AppleFMError.contextOverflow)
                    default:
                        continuation.finish(throwing: err)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Best-effort weight prewarm. Foundation Models lazy-loads on the first
    /// `respond(...)`, which adds a few hundred ms of first-token latency.
    /// Calling `prewarm()` at app launch — when `availability == .available` —
    /// amortises that cost into the splash phase the user already pays for.
    func prewarm() {
        let session = LanguageModelSession()
        session.prewarm()
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off in System Settings"
        case .modelNotReady:
            return "Apple's on-device model is still downloading"
        @unknown default:
            return "Apple model unavailable"
        }
    }
}

@available(macOS 26, *)
enum AppleFMError: Error, LocalizedError {
    /// Apple's documented `LanguageModelSession.GenerationError.exceededContextWindowSize`.
    /// Surfaced as a recoverable error so the router can fall through to the
    /// bundled-Gemma backend, which has its own (smaller) context window.
    case contextOverflow

    var errorDescription: String? {
        switch self {
        case .contextOverflow:
            return "Apple Intelligence context window exceeded."
        }
    }
}
#endif
