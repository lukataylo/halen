import Foundation

struct InferenceRequest: Sendable {
    var prompt: String
    var tier: ModelTier
    var maxTokens: Int = 256
    var temperature: Double = 0.2
    var stop: [String] = []
}

struct InferenceResponse: Sendable {
    var text: String
    var modelId: String
    var latencyMs: Int
}

protocol InferenceClient: Sendable {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse
}
