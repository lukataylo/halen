import Foundation

/// Inference backend backed by a Gemma model running on the bundled llama.cpp
/// runtime. The Gemma 3 1B GGUF ships inside the app bundle, so this backend is
/// always available with zero install — it's the default the router falls back
/// to when neither Apple Intelligence nor Ollama is present.
///
/// The 1B model is strong at classification/extraction but weak at open-ended
/// generation, so `capability.strongAt` is `.classification` only — the router
/// still *can* route generation here (degraded) when nothing better exists.
///
/// An `actor`: the underlying `LlamaContext` is loaded lazily and reused, and
/// must never be touched concurrently.
actor LlamaCppBackend: InferenceBackend {
    nonisolated let kind: BackendKind = .bundledLlama
    nonisolated let capability = BackendCapability(
        servesTiers: [.small, .medium],
        strongAt: [.classification],
        basePriority: 5
    )

    private var loadedContext: LlamaContext?
    private var loadFailed = false

    /// The bundled GGUF, copied into `Contents/Resources/Models/` by build-app.sh.
    static var modelURL: URL? {
        Bundle.main.url(forResource: "gemma-3-1b-it-Q4_K_M", withExtension: "gguf", subdirectory: "Models")
    }

    func availability() async -> BackendAvailability {
        if loadFailed { return .unavailable(reason: "Bundled model failed to load") }
        guard Self.modelURL != nil else {
            return .unavailable(reason: "Bundled model missing from app bundle")
        }
        return .available
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let context = try ensureContext()
        let start = Date()
        // Gemma instruction-tuned chat template.
        let prompt = "<start_of_turn>user\n\(request.prompt)<end_of_turn>\n<start_of_turn>model\n"
        let raw = await context.generate(
            prompt: prompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            stop: request.stop
        )
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LlamaBackendError.emptyResponse }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return InferenceResponse(text: text, modelId: "bundled/gemma-3-1b", latencyMs: latency)
    }

    /// Loads the bundled model on first use and keeps it warm. Loading is slow
    /// (seconds, ~1-2GB RAM) so it's deferred until the first request.
    private func ensureContext() throws -> LlamaContext {
        if let loadedContext { return loadedContext }
        if loadFailed { throw LlamaBackendError.modelUnavailable }
        guard let url = Self.modelURL else {
            loadFailed = true
            throw LlamaBackendError.modelUnavailable
        }
        do {
            let context = try LlamaContext.load(modelPath: url.path)
            loadedContext = context
            Log.info("LlamaCppBackend: loaded \(url.lastPathComponent)")
            return context
        } catch {
            loadFailed = true
            Log.warn("LlamaCppBackend: model load failed: \(error)")
            throw error
        }
    }
}

enum LlamaBackendError: Error, CustomStringConvertible {
    case modelUnavailable
    case emptyResponse

    var description: String {
        switch self {
        case .modelUnavailable: return "Bundled llama.cpp model is unavailable"
        case .emptyResponse:    return "Bundled model returned an empty completion"
        }
    }
}
