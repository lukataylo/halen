import Foundation

/// Returns canned responses so the overlay and feature modules can be built and
/// exercised before MLX + Gemma 4 weights are wired up in M2.
final class StubInferenceClient: InferenceClient {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let start = Date()
        try await Task.sleep(for: .milliseconds(50))
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let text = "[stub:\(request.tier.rawValue)] \(request.prompt.prefix(40))…"
        return InferenceResponse(
            text: text,
            modelId: request.tier.defaultModelId,
            latencyMs: latency
        )
    }
}
