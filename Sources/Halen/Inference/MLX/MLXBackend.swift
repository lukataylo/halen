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
/// This is the scaffold. The backend compiles and is wired into the router
/// today, but reports `.unavailable` until the `mlx-swift-examples` package
/// is added to `Package.swift` (see the commented block there). Once the
/// dependency is present, `canImport(MLXLLM)` flips true and the real
/// implementation in the `#if canImport(MLXLLM)` extension below activates.
///
/// Remaining work before MLX can serve traffic:
///   1. Add the `mlx-swift-examples` dependency in `Package.swift`.
///   2. Confirm the `mlx-community` repo id in `MLXModelLocation`.
///   3. Verify the `MLXLLM` / `MLXLMCommon` API calls below against the
///      pinned package version (the generate API has drifted across
///      releases) and resolve any signature differences.
///   4. Wire MLX into `InferenceBackends.prewarmAll` if a prewarm path
///      exists, and add token streaming once the streaming inference path
///      lands (see the separate streaming branch).
///
/// An `actor`: the loaded model container is reused across requests and must
/// not be torn down concurrently — same lifecycle contract as `LlamaCppBackend`.
actor MLXBackend: InferenceBackend {
    nonisolated let kind: BackendKind = .mlx
    nonisolated let capability = BackendCapability(
        servesTiers: [.small, .medium],
        strongAt: [.classification, .generation],
        // Lower = preferred on a tie. Slightly ahead of bundled llama.cpp (5)
        // because, once proven, MLX is the faster local path on Apple Silicon.
        basePriority: 4
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

        // Gemma instruction-tuned chat template — identical framing to
        // `LlamaCppBackend` so the two local backends behave the same.
        let prompt = "<start_of_turn>user\n\(request.prompt)<end_of_turn>\n<start_of_turn>model\n"
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: Float(request.temperature)
        )

        let text = try await container.perform { (context: ModelContext) -> String in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            let result = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context
            ) { _ in .more }
            return result.output
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
}
#endif
