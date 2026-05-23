import Foundation

/// Inference backend backed by a llama.cpp-loaded GGUF model. The exact model
/// is determined by the `ModelSpec` passed at init — Gemma 4 E4B for the
/// default `.medium` generation path, Qwen 2.5 0.5B for the `.classifier`
/// hot path. The GGUF is resolved via `ModelLocation.resolved(for:)`:
///
///   * default slim build → user must download via `ModelDownloader` before
///     this backend becomes `.available` (Apple Intelligence is the
///     zero-install path; bundled models are the fallback for older macOS or
///     for users who explicitly opt in).
///   * `BUNDLE_MODEL=1` build → the GGUF ships inside the .app, so the
///     backend is `.available` with zero download.
///
/// `capability.servesTiers` / `strongAt` come from the spec, so the router
/// can prefer a backend whose model matches the request's tier + task kind.
///
/// An `actor`: the underlying `LlamaContext` is loaded lazily and reused, and
/// must never be touched concurrently.
actor LlamaCppBackend: InferenceBackend {
    nonisolated let kind: BackendKind = .bundledLlama
    nonisolated let capability: BackendCapability
    nonisolated let spec: ModelSpec

    private var loadedContext: LlamaContext?
    private var loadFailed = false

    /// The model + KV cache is ~1 GB resident for Gemma, ~500 MB for Qwen 0.5B.
    /// A menubar app runs all day, so the context is evicted after a stretch
    /// of no requests and transparently reloaded (a few seconds) on the next.
    private var idleUnloadTask: Task<Void, Never>?
    private let idleUnloadInterval: TimeInterval = 5 * 60

    init(spec: ModelSpec) {
        self.spec = spec
        self.capability = BackendCapability(
            servesTiers: spec.servesTiers,
            strongAt: spec.strongAt,
            basePriority: spec.basePriority
        )
    }

    /// Whichever copy of the GGUF is on disk — downloaded path wins over
    /// bundled. `nil` when neither is present (the default slim install on a
    /// Mac without Apple Intelligence, before the user downloads).
    private var modelURL: URL? { ModelLocation.resolved(for: spec) }

    func availability() async -> BackendAvailability {
        if loadFailed { return .unavailable(reason: "\(spec.displayName) failed to load") }
        if loadedContext != nil { return .available }   // already loaded — proven good
        guard let url = modelURL else {
            return .unavailable(reason: "\(spec.displayName) not downloaded yet — visit Settings → Inference")
        }
        guard Self.modelLooksValid(at: url) else {
            return .unavailable(reason: "\(spec.displayName) file looks corrupt or incomplete")
        }
        return .available
    }

    /// Eagerly load the model into memory so the first user-facing inference
    /// doesn't pay the 3-5s cold-load tax. Safe to call at app start (or any
    /// time after); idempotent — a second call is a no-op once loaded.
    /// Returns silently on failure — `availability()` will report the
    /// problem the next time the router asks.
    func prewarm() async {
        guard loadedContext == nil, !loadFailed else { return }
        _ = try? ensureContext()
    }

    /// Cheap integrity probe: confirms the GGUF exists, starts with the
    /// `GGUF` magic, and is large enough to be a real model rather than a
    /// truncated copy. It deliberately does NOT load the model — that costs
    /// seconds and GBs of RAM. A well-formed but semantically corrupt file is
    /// still only caught at load time, after which `loadFailed` latches and
    /// `availability()` reports unavailable so the router stops routing here.
    private static func modelLooksValid(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("GGUF".utf8) else {
            return false
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Sanity floor — even the smallest classifier we ship (Qwen 0.5B
        // Q4_K_M) is ~400 MB. Anything below 100 MB is a partial / truncated
        // download masquerading as a real file.
        return size >= 100_000_000
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        let context = try ensureContext()
        // Push the idle-eviction deadline out on every request, success or not.
        defer { scheduleIdleUnload() }
        let start = Date()
        let prompt = spec.chatTemplate(request.prompt)
        // The model's EOG stops generation on its own; the explicit stops are
        // a guard in case the model emits a turn marker as plain text instead
        // of the control token.
        let raw = await context.generate(
            prompt: prompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            stop: request.stop + spec.extraStopTokens
        )
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LlamaBackendError.emptyResponse }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return InferenceResponse(text: text, modelId: spec.id, latencyMs: latency)
    }

    /// Token-streaming variant of `complete`. `nonisolated` so it satisfies the
    /// non-`async` protocol requirement from an `actor` — the real work hops
    /// onto the actor inside the spawned `Task`.
    nonisolated func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.runStreaming(request, into: continuation) }
            // Consumer stopped reading (panel closed, plugin cancelled) — cancel
            // the generation Task; `LlamaContext.generate` checks `Task.isCancelled`.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreaming(
        _ request: InferenceRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let context: LlamaContext
        do {
            context = try ensureContext()
        } catch {
            continuation.finish(throwing: error)
            return
        }
        defer { scheduleIdleUnload() }

        let prompt = spec.chatTemplate(request.prompt)
        let raw = await context.generate(
            prompt: prompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            stop: request.stop + spec.extraStopTokens,
            onToken: { snapshot in
                continuation.yield(snapshot.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            continuation.finish(throwing: LlamaBackendError.emptyResponse)
            return
        }
        // Re-emit the trimmed, authoritative final snapshot, then close.
        continuation.yield(text)
        continuation.finish()
    }

    /// Loads the model on first use and keeps it warm. Loading is slow
    /// (seconds, hundreds of MB to a few GB of RAM depending on the spec) so
    /// it's deferred until the first request — unless the host calls
    /// `prewarm()` at startup to pay that cost up front.
    private func ensureContext() throws -> LlamaContext {
        if let loadedContext { return loadedContext }
        if loadFailed { throw LlamaBackendError.modelUnavailable }
        guard let url = modelURL else {
            loadFailed = true
            throw LlamaBackendError.modelUnavailable
        }
        do {
            let context = try LlamaContext.load(modelPath: url.path)
            loadedContext = context
            Log.info("LlamaCppBackend[\(spec.id)]: loaded \(url.lastPathComponent)")
            return context
        } catch {
            loadFailed = true
            Log.warn("LlamaCppBackend[\(spec.id)]: model load failed: \(error)")
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
        Log.info("LlamaCppBackend[\(spec.id)]: released idle model context")
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
