import Foundation

/// The single site that constructs the concrete backend set — and the only place
/// `AppleFMBackend` is referenced, gated behind `#available` so the macOS-14
/// deployment target is preserved (`AppleFMBackend` itself is `@available(macOS 26, *)`
/// and `#if canImport(FoundationModels)`-guarded).
enum InferenceBackends {
    static func makeAll() -> [InferenceBackend] {
        // On macOS 26+ Apple Intelligence is the preferred default (zero
        // install, better model quality than bundled 1B Gemma). The bundled-
        // llama backend covers older macOS + Macs without Apple Intelligence,
        // but requires either a `BUNDLE_MODEL=1` build OR an explicit user
        // download via ModelDownloader. Ollama remains opt-in for the large
        // tier. Array order doesn't matter; the router sorts by
        // `InferenceSettings.preferenceOrder`.
        var backends: [InferenceBackend] = [LlamaCppBackend(), OllamaBackend()]
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            backends.append(AppleFMBackend())
        }
        #endif
        return backends
    }

    /// Best-effort prewarm of any backend that supports it. Today only Apple
    /// Foundation Models does — calling `prewarm()` at app launch (once the
    /// model reports available) saves a few hundred ms on the first inference,
    /// during the splash phase the user already pays for. No-op on backends
    /// that don't need warming.
    @MainActor
    static func prewarmAll(_ backends: [InferenceBackend]) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            for backend in backends {
                guard let fm = backend as? AppleFMBackend else { continue }
                if await fm.availability().isAvailable {
                    fm.prewarm()
                    Log.info("AppleFMBackend: prewarmed")
                }
            }
        }
        #endif
    }
}
