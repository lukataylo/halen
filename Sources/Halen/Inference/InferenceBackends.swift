import Foundation

/// The single site that constructs the concrete backend set — and the only place
/// `AppleFMBackend` is referenced, gated behind `#available` so the macOS-14
/// deployment target is preserved (`AppleFMBackend` itself is `@available(macOS 26, *)`
/// and `#if canImport(FoundationModels)`-guarded).
enum InferenceBackends {
    static func makeAll() -> [InferenceBackend] {
        // Bundled llama.cpp ships in the app, so it's always available — the
        // zero-install default. Ollama and Apple Intelligence are optional.
        // Array order doesn't matter; the router sorts by user preference.
        var backends: [InferenceBackend] = [LlamaCppBackend(), OllamaBackend()]
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            backends.append(AppleFMBackend())
        }
        #endif
        return backends
    }
}
