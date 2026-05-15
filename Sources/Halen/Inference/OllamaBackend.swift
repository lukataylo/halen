import Foundation

/// Wraps the existing `OllamaInferenceClient` as a router backend. The client
/// itself is unchanged — it still owns the wire format and tier→model mapping;
/// this only adds an availability probe and capability metadata.
///
/// Ollama is the only backend that serves `.large` (the bigger Gemma 4 tiers
/// the bundled model can't reach), so it stays in the menu even once a local
/// runtime ships.
final class OllamaBackend: InferenceBackend {
    let kind: BackendKind = .ollama
    let capability = BackendCapability(
        servesTiers: [.small, .medium, .large],
        strongAt: [.classification, .generation],
        basePriority: 20
    )

    private let baseURL: URL
    private let client: OllamaInferenceClient

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
        self.client = OllamaInferenceClient(baseURL: baseURL)
    }

    func availability() async -> BackendAvailability {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        // 1 s, not 2: a refused localhost connection returns immediately;
        // only a hung daemon needs the timeout, and the router caches a
        // negative result for 60 s so we don't probe on a tight loop.
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unavailable(reason: "Ollama not reachable")
            }
            return .available
        } catch {
            return .unavailable(reason: "Ollama not reachable — run `ollama serve`")
        }
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        try await client.complete(request)
    }
}
