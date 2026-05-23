import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

/// Inference backend backed by Apple's **MLX** array framework — the
/// Apple-Silicon-native alternative to the bundled llama.cpp runtime.
///
/// Why MLX as a second local backend:
///  * MLX is built for Apple Silicon's unified memory and fuses its own
///    Metal kernels, so on an M-series Mac it is typically faster than
///    llama.cpp for the same quantised model.
///  * It stays a pure-Swift dependency (`mlx-swift` / `mlx-swift-examples`),
///    so no extra prebuilt xcframework to vendor and codesign.
///
/// It runs *alongside* `LlamaCppBackend`, not instead of it: the router
/// (`RouterInferenceClient`) picks per request from `InferenceSettings`'
/// preference order, so MLX can be benchmarked head-to-head and promoted
/// only once it is proven on real hardware.
///
/// ── Integration status ──────────────────────────────────────────────────
/// The Swift code below — `loadContainer`, `runMLX`, `runStreaming`,
/// `prewarm` — is complete and verified against `mlx-swift-examples` v2.29.
/// What's missing is the **Metal shader pipeline**. mlx-swift's own README
/// states: *"SwiftPM (command line) cannot build the Metal shaders so the
/// ultimate build has to be done via Xcode."* Activating the dep in
/// `Package.swift` and `swift build`-ing produces a binary that crashes
/// at first use with `MLX error: Failed to load the default metallib`.
///
/// Activation arc (deferred until perf justifies the build-pipeline lift):
///   1. Switch (or dual-build) the project through `xcodebuild` so MLX's
///      Metal compiler stage runs and `mlx-swift_Cmlx.bundle` is emitted.
///   2. Update `scripts/build-app.sh` to copy that bundle into the .app's
///      Contents/Resources/ alongside the existing llama framework.
///   3. Uncomment the `mlx-swift-examples` dep in `Package.swift` and the
///      product entries in the Halen target's `dependencies:`.
///   4. CI workflow (`.github/workflows/...`) will need the same change.
///
/// Qwen 0.5B on llama.cpp already gives sub-100ms warm classification,
/// so MLX is a perf-ceiling lift rather than a must-ship; the scaffold
/// stays in tree so the activation arc is mechanical when picked up.
///
/// An `actor`: the loaded model container is reused across requests and must
/// not be torn down concurrently — same lifecycle contract as `LlamaCppBackend`.
actor MLXBackend: InferenceBackend {
    nonisolated let kind: BackendKind = .mlx
    nonisolated let capability = BackendCapability(
        // `.classifier` is the primary tier — this backend ships pointing
        // at the same Qwen 2.5 0.5B Instruct the llama.cpp `.classifier`
        // backend serves, so the router can A/B between MLX and llama.cpp
        // on identical work. `.small`/`.medium` are listed as fallbacks
        // for callers that didn't opt into `.classifier`.
        servesTiers: [.classifier, .small, .medium],
        strongAt: [.classification, .generation],
        // Lower = preferred on a tie. `basePriority: 2` puts MLX *ahead* of
        // the llama.cpp Qwen backend (3) so once proven, MLX wins
        // identical-tier ties. The router still falls through to llama.cpp
        // if MLX reports unavailable (Intel Mac, dep missing, load failed).
        basePriority: 2
    )

    #if canImport(MLXLLM)
    /// Lazily loaded, then kept warm. `ModelContainer` serialises access to
    /// the model internally, so the actor only guards the load/unload race.
    private var container: ModelContainer?
    private var loadFailed = false
    #endif

    func availability() async -> BackendAvailability {
        #if canImport(MLXLLM)
        if loadFailed { return .unavailable(reason: "MLX model failed to load") }
        if container != nil { return .available }
        // MLX downloads the repo on first use via the Hub client, so "not yet
        // cached" is not an error — the first request pays the download. Report
        // available; a genuine load failure latches `loadFailed` above.
        return .available
        #else
        return .unavailable(reason:
            "MLX runtime not yet integrated — add the mlx-swift-examples dependency in Package.swift")
        #endif
    }

    func complete(_ request: InferenceRequest) async throws -> InferenceResponse {
        #if canImport(MLXLLM)
        return try await runMLX(request)
        #else
        throw MLXBackendError.runtimeNotIntegrated
        #endif
    }

    /// Streaming variant — yields the cumulative completion as MLX produces
    /// each chunk. `nonisolated` so it satisfies the non-`async` protocol
    /// requirement from an `actor` (the real work hops onto the actor
    /// inside the spawned `Task`). When MLX isn't compiled in, falls through
    /// to the `InferenceBackend` default, which runs `complete()` and emits
    /// the whole result as a single snapshot.
    #if canImport(MLXLLM)
    nonisolated func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.runStreaming(request, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    /// Eagerly load the model into memory so the first user-facing request
    /// doesn't pay the Hub-download + weight-load cost. Idempotent — a
    /// second call is a no-op once loaded. Mirrors `LlamaCppBackend.prewarm()`
    /// so `InferenceBackends.prewarmAll` can fan out to either backend.
    /// Returns silently on failure; `availability()` will surface the issue
    /// the next time the router probes.
    func prewarm() async {
        #if canImport(MLXLLM)
        guard container == nil, !loadFailed else { return }
        _ = try? await loadContainer()
        #endif
    }
}

enum MLXBackendError: Error, LocalizedError, CustomStringConvertible {
    /// Raised by `complete(_:)` when the build has no `MLXLLM` dependency —
    /// the router treats it like any backend failure and falls through.
    case runtimeNotIntegrated
    case modelLoadFailed(String)
    case emptyResponse

    var description: String {
        switch self {
        case .runtimeNotIntegrated:
            return "MLX runtime is not integrated in this build"
        case .modelLoadFailed(let detail):
            return "MLX model failed to load: \(detail)"
        case .emptyResponse:
            return "MLX model returned an empty completion"
        }
    }

    var errorDescription: String? { description }
}

// MARK: - MLX implementation (active once the dependency is present)
//
// DRAFT — the calls below target the `MLXLLM` / `MLXLMCommon` API as of
// mlx-swift-examples v2.x. That API has changed across releases; verify each
// signature against the pinned package version before relying on this path.

#if canImport(MLXLLM)
extension MLXBackend {
    private func loadContainer() async throws -> ModelContainer {
        if let container { return container }
        if loadFailed { throw MLXBackendError.modelLoadFailed("previous load failed") }
        do {
            let configuration = ModelConfiguration(id: MLXModelLocation.repoId)
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
            container = loaded
            Log.info("MLXBackend: loaded \(MLXModelLocation.repoId)")
            return loaded
        } catch {
            loadFailed = true
            Log.warn("MLXBackend: model load failed: \(error)")
            throw MLXBackendError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func runMLX(_ request: InferenceRequest) async throws -> InferenceResponse {
        let start = Date()
        let container = try await loadContainer()

        // Qwen instruction-tuned chat template (ChatML). Must match the
        // template `LlamaCppBackend` uses for the same model — Qwen does NOT
        // use Gemma's `<start_of_turn>` framing; getting this wrong yields
        // garbled or empty completions.
        let prompt = "<|im_start|>user\n\(request.prompt)<|im_end|>\n<|im_start|>assistant\n"
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: Float(request.temperature)
        )

        // `mlx-swift-examples` ships three `generate(...)` overloads: two
        // legacy ones taking a `didGenerate` closure (`[Int] -> _` vs
        // `Int -> _`) — those are ambiguous when the closure is the
        // shorthand `{ _ in .more }` — and a modern one returning
        // `AsyncStream<Generation>`. The modern variant is unambiguous
        // (no `didGenerate:` label) and also gives us the chunked stream
        // the streaming path will need; collect into a single string here.
        let text: String = try await container.perform { (context: ModelContext) -> String in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            let stream = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context)
            var accumulator = ""
            for await event in stream {
                if case .chunk(let chunk) = event {
                    accumulator += chunk
                }
            }
            return accumulator
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MLXBackendError.emptyResponse }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return InferenceResponse(
            text: trimmed,
            modelId: "mlx/\(MLXModelLocation.repoId)",
            latencyMs: latency
        )
    }

    /// Token-streaming variant. Each yielded value is the **cumulative**
    /// completion text so far (matches `LlamaCppBackend.stream`'s contract).
    /// Consumers (SentimentGuard's rephrase pane, SnippetExpander) render
    /// the latest snapshot directly.
    fileprivate func runStreaming(
        _ request: InferenceRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let container: ModelContainer
        do {
            container = try await loadContainer()
        } catch {
            continuation.finish(throwing: error)
            return
        }

        let prompt = "<|im_start|>user\n\(request.prompt)<|im_end|>\n<|im_start|>assistant\n"
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: Float(request.temperature)
        )

        do {
            try await container.perform { (context: ModelContext) async throws -> Void in
                let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
                let stream = try MLXLMCommon.generate(
                    input: input, parameters: parameters, context: context)
                var accumulator = ""
                for await event in stream {
                    if Task.isCancelled { return }
                    if case .chunk(let chunk) = event {
                        accumulator += chunk
                        continuation.yield(accumulator.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                // Final authoritative snapshot, then close.
                let trimmed = accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continuation.finish(throwing: MLXBackendError.emptyResponse)
                } else {
                    continuation.yield(trimmed)
                    continuation.finish()
                }
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
#endif
