import Foundation

/// HTTP client for a local Ollama daemon (default `http://localhost:11434`).
/// Maps `ModelTier` to the local Gemma 4 model name. Used by every plugin that
/// needs language reasoning — sentiment classification, summarisation, etc.
///
/// Why Ollama instead of MLX/llama.cpp directly: the user already has
/// `gemma4:e2b` and `gemma4:e4b` pulled, the daemon handles model lifecycle
/// (warm-up, quantisation, swapping), and the JSON wire format is trivially
/// debuggable. We can swap to MLX later for sub-100ms paths without changing
/// any plugin code — they only see `InferenceClient`.
final class OllamaInferenceClient: InferenceClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let start = Date()
        let modelId = modelName(for: request.tier)

        let body = ChatRequest(
            model: modelId,
            messages: [.init(role: "user", content: request.prompt)],
            stream: false,
            // Gemma 4 is a thinking model. Every Halen use case (classify,
            // summarise, rephrase, brief) wants the *output*, not chain-of-
            // thought — and with thinking on, the reasoning tokens count
            // against num_predict, so a long think can exhaust the budget and
            // return an empty `content`. Disable it across the board.
            think: false,
            options: .init(
                temperature: request.temperature,
                num_predict: request.maxTokens,
                stop: request.stop.isEmpty ? nil : request.stop
            )
        )

        var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.noHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.badStatus(http.statusCode, body: bodyText)
        }

        let chat = try decoder.decode(ChatResponse.self, from: data)
        // An empty body is a failure, not a valid completion — throw so the
        // router falls through to the next backend instead of returning "".
        guard !chat.message.content.isEmpty else {
            throw OllamaError.emptyResponse
        }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return InferenceResponse(
            text: chat.message.content,
            modelId: modelId,
            latencyMs: latency
        )
    }

    private func modelName(for tier: ModelTier) -> String {
        switch tier {
        case .small:  return "gemma4:e2b"
        case .medium: return "gemma4:e4b"
        case .large:  return "gemma4:26b"
        }
    }
}

enum OllamaError: Error, CustomStringConvertible {
    case noHTTPResponse
    case badStatus(Int, body: String)
    case emptyResponse

    var description: String {
        switch self {
        case .noHTTPResponse: return "Ollama: no HTTP response"
        case .badStatus(let code, let body): return "Ollama HTTP \(code): \(body.prefix(200))"
        case .emptyResponse: return "Ollama: empty completion body"
        }
    }
}

// MARK: - Wire format

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let think: Bool
    let options: ChatOptions
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatOptions: Encodable {
    let temperature: Double
    let num_predict: Int
    let stop: [String]?
}

private struct ChatResponse: Decodable {
    let message: ChatMessage
}
