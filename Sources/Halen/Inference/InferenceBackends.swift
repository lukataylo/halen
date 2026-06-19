import Foundation

/// The single site that constructs the concrete backend set — and the only place
/// `AppleFMBackend` is referenced, gated behind `#available` so the macOS-14
/// deployment target is preserved (`AppleFMBackend` itself is `@available(macOS 26, *)`
/// and `#if canImport(FoundationModels)`-guarded).
enum InferenceBackends {
    static func makeAll() -> [InferenceBackend] {
        // On macOS 26+ Apple Intelligence is the preferred default (zero
        // install, better model quality than bundled 1B Gemma). The bundled-
        // llama backends cover older macOS + Macs without Apple Intelligence,
        // but require either a `BUNDLE_MODEL=1` build OR an explicit user
        // download via ModelDownloader. Ollama remains opt-in for the large
        // tier. Array order doesn't matter; the router sorts by
        // `InferenceSettings.preferenceOrder`.
        //
        // Two `LlamaCppBackend` instances ship: a Qwen 2.5 0.5B for the
        // dedicated `.classifier` tier (sub-second classification path) and
        // a Gemma 4 E4B for `.small`/`.medium` generation/rewrite. Each owns
        // its own context + idle-eviction timer.
        //
        // An MLX-backed parallel of `LlamaCppBackend(spec: .qwen…)` exists on
        // the `mlx-activation` branch — pending an xcodebuild pipeline lift
        // since `swift build` cannot compile mlx-swift's Metal shaders.
        var backends: [InferenceBackend] = [
            LlamaCppBackend(spec: .qwen25_05B_Q4_K_M),
            LlamaCppBackend(spec: .gemma4E4B_IQ4_XS),
            OllamaBackend(),
        ]
        // Dedicated compaction model (Qwen3-4B-Instruct-2507) — registered ONLY
        // when its GGUF is already downloaded. It must not enter the router as an
        // unavailable backend: the router caches availability by `BackendKind`,
        // and every LlamaCppBackend shares `.bundledLlama`, so probing an
        // un-downloaded compaction model would cache the whole bundled-llama kind
        // as unavailable and starve Gemma of `.medium` traffic. Gating on the
        // file's presence keeps it out until the opt-in download completes (the
        // backend is picked up on the next launch); until then `.compaction`
        // requests fall back to Gemma.
        if ModelLocation.isAvailable(for: .qwen3_4B_2507_Q4_K_M) {
            backends.append(LlamaCppBackend(spec: .qwen3_4B_2507_Q4_K_M))
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            backends.append(AppleFMBackend())
        }
        #endif
        return backends
    }

    /// Eagerly load every model that's available, in parallel, so the first
    /// user-facing inference doesn't pay the cold-load tax. Called from
    /// `AppCoordinator.start()` once observers are up — by the time the user
    /// types their first paragraph, both Qwen (classifier) and Gemma
    /// (rewrite) are typically warm.
    ///
    /// Apple FM uses its own lightweight `prewarm()`. Backends that can't (or
    /// don't need to) prewarm are skipped silently.
    @MainActor
    static func prewarmAll(_ backends: [InferenceBackend]) async {
        await withTaskGroup(of: Void.self) { group in
            for backend in backends {
                if let llama = backend as? LlamaCppBackend {
                    group.addTask {
                        if await llama.availability().isAvailable {
                            await llama.prewarm()
                            Log.info("LlamaCppBackend[\(llama.spec.id)]: prewarmed")
                        }
                    }
                }
                #if canImport(FoundationModels)
                if #available(macOS 26, *), let fm = backend as? AppleFMBackend {
                    group.addTask {
                        if await fm.availability().isAvailable {
                            fm.prewarm()
                            Log.info("AppleFMBackend: prewarmed")
                        }
                    }
                }
                #endif
            }
        }
    }
}
