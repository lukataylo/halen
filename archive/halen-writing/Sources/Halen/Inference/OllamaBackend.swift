import Foundation

/// Wraps the existing `OllamaInferenceClient` as a router backend. The client
/// itself is unchanged — it still owns the wire format and tier→model mapping;
/// this only adds an availability probe and capability metadata.
///
/// Ollama is the only backend that serves `.large` (the bigger Gemma 4 tiers
/// the bundled model can't reach), so it stays in the menu even once a local
/// runtime ships.
///
/// **Endpoint:** read from `OllamaSettings.currentBaseURL()` on every call so
/// Settings changes take effect without restart. The client is cached and
/// rebuilt only when the URL actually changes — steady-state calls never pay
/// the URLSession-init cost. `@unchecked Sendable` because the cache is
/// mutable; the NSLock provides the synchronization the inherited Sendable
/// contract requires.
final class OllamaBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .ollama
    let capability = BackendCapability(
        // `.classifier` listed as a last-resort fallback so classification
        // still works when both Qwen 0.5B AND Apple FM are unavailable. The
        // higher `basePriority` (20) keeps Ollama last in the ladder.
        servesTiers: [.classifier, .small, .medium, .large],
        strongAt: [.classification, .generation],
        basePriority: 20
    )

    private var cachedClient: OllamaInferenceClient
    private var cachedURL: URL
    private let lock = NSLock()

    init() {
        let url = OllamaSettings.currentBaseURL()
        self.cachedURL = url
        self.cachedClient = OllamaInferenceClient(baseURL: url)
    }

    /// Snapshot the active (URL, client) pair, rebuilding the client only
    /// if the configured URL has changed since the last call. Atomic under
    /// `lock` so a Settings change racing with an in-flight call sees a
    /// consistent pair.
    private func snapshot() -> (URL, OllamaInferenceClient) {
        let url = OllamaSettings.currentBaseURL()
        lock.lock()
        defer { lock.unlock() }
        if url != cachedURL {
            cachedURL = url
            cachedClient = OllamaInferenceClient(baseURL: url)
            Log.info("OllamaBackend: switched to \(url.absoluteString)")
        }
        return (cachedURL, cachedClient)
    }

    func availability() async -> BackendAvailability {
        let (url, _) = snapshot()
        var request = URLRequest(url: url.appending(path: "api/tags"))
        // 1 s, not 2: a refused localhost connection returns immediately;
        // only a hung daemon needs the timeout, and the router caches a
        // negative result for 60 s so we don't probe on a tight loop.
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unavailable(reason: "Ollama not reachable at \(url.host ?? url.absoluteString)")
            }
            return .available
        } catch {
            // Surface the configured host in the error so a user with a
            // non-default port understands which endpoint failed.
            let target = url.host.map { "\($0):\(url.port ?? 11434)" } ?? url.absoluteString
            return .unavailable(reason: "Ollama not reachable at \(target) — run `ollama serve`")
        }
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let (_, client) = snapshot()
        return try await client.complete(request)
    }
}
