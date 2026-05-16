import Foundation

/// Inference backend backed by a Gemma model running on the bundled llama.cpp
/// runtime. The GGUF is resolved via `ModelLocation`:
///
///   * default slim build → user must download via `ModelDownloader` before
///     this backend becomes `.available` (Apple Intelligence is the
///     zero-install path; bundled-Gemma is the fallback for older macOS or
///     for users who explicitly opt in).
///   * `BUNDLE_MODEL=1` build → the GGUF ships inside the .app, so the
///     backend is `.available` with zero download.
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

    /// The model + KV cache is ~1 GB resident. A menubar app runs all day, so
    /// the context is evicted after a stretch of no requests and transparently
    /// reloaded (a few seconds) on the next one.
    private var idleUnloadTask: Task<Void, Never>?
    private let idleUnloadInterval: TimeInterval = 5 * 60

    /// Whichever copy of the GGUF is on disk — downloaded path wins over
    /// bundled. `nil` when neither is present (the default slim install on a
    /// Mac without Apple Intelligence, before the user downloads).
    static var modelURL: URL? { ModelLocation.resolved }

    func availability() async -> BackendAvailability {
        if loadFailed { return .unavailable(reason: "Built-in model failed to load") }
        if loadedContext != nil { return .available }   // already loaded — proven good
        guard let url = Self.modelURL else {
            return .unavailable(reason: "Built-in model not downloaded yet — visit Settings → Inference")
        }
        guard Self.modelLooksValid(at: url) else {
            return .unavailable(reason: "Built-in model file looks corrupt or incomplete")
        }
        return .available
    }

    /// Cheap integrity probe: confirms the bundled GGUF exists, starts with the
    /// `GGUF` magic, and is large enough to be a real 1B model rather than a
    /// truncated or partial copy. It deliberately does NOT load the model —
    /// that costs seconds and GBs of RAM. A well-formed but semantically corrupt
    /// file is still only caught at load time, after which `loadFailed` latches
    /// and `availability()` reports unavailable so the router stops routing here.
    private static func modelLooksValid(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("GGUF".utf8) else {
            return false
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size >= 100_000_000   // any real 1B GGUF is hundreds of MB
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let context = try ensureContext()
        // Push the idle-eviction deadline out on every request, success or not.
        defer { scheduleIdleUnload() }
        let start = Date()
        // Gemma instruction-tuned chat template.
        let prompt = "<start_of_turn>user\n\(request.prompt)<end_of_turn>\n<start_of_turn>model\n"
        // `<end_of_turn>` is the real EOG token and stops generation on its own;
        // the explicit stops are a guard in case the model emits a turn marker
        // as plain text instead of the control token.
        let raw = await context.generate(
            prompt: prompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            stop: request.stop + ["<end_of_turn>", "<start_of_turn>"]
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

    /// (Re)arm the idle-eviction timer. Each request resets it, so the model is
    /// only released after `idleUnloadInterval` of genuine inactivity.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self, idleUnloadInterval] in
            try? await Task.sleep(for: .seconds(idleUnloadInterval))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    /// Drop the warm context. `LlamaContext.deinit` frees the model, context and
    /// batch; the next `complete()` transparently reloads. Safe to run even with
    /// a `complete()` in flight — that call holds its own strong reference, so
    /// the underlying context survives until it finishes.
    private func unloadIfIdle() {
        guard loadedContext != nil else { return }
        loadedContext = nil
        idleUnloadTask = nil
        Log.info("LlamaCppBackend: released idle model context")
    }
}

enum LlamaBackendError: Error, LocalizedError, CustomStringConvertible {
    case modelUnavailable
    case emptyResponse

    var description: String {
        switch self {
        case .modelUnavailable: return "Bundled llama.cpp model is unavailable"
        case .emptyResponse:    return "Bundled model returned an empty completion"
        }
    }

    var errorDescription: String? { description }
}
