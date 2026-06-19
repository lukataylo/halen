import Foundation

/// Everything `LlamaCppBackend` + `ModelDownloader` need to know about a
/// specific bundled GGUF model: where to fetch it, how to verify it, where it
/// lives on disk, and how to wrap a user prompt for it.
///
/// Pre-spec the codebase hardcoded one Gemma 4 E4B as "the" bundled model;
/// adding the Qwen 2.5 0.5B classifier required parameterising the backend
/// + downloader so two (and later N) GGUFs can coexist behind the same
/// machinery. Pure-data — every field is `Sendable` and frozen at init.
struct ModelSpec: Sendable {
    /// Stable identifier surfaced in `InferenceResponse.modelId` and used as
    /// the namespace for download-state UserDefaults. Reverse-DNS style.
    let id: String

    /// On-disk filename (also the trailing path component of the HuggingFace
    /// asset URL). Used by `ModelLocation` to derive download + bundled paths.
    let filename: String

    /// Resource name (no extension) for the `BUNDLE_MODEL=1` lookup in
    /// `Bundle.main.url(forResource:withExtension:subdirectory:)`.
    let bundleResourceName: String

    /// User-facing label for Settings / Plugin Store copy.
    let displayName: String

    /// Canonical download URL — the HuggingFace LFS mirror.
    let sourceURL: URL

    /// Expected file size in bytes. Drives the progress denominator and the
    /// fast-fail sanity check before the (~3s) SHA-256 pass.
    let expectedSize: Int64

    /// Pinned content hash from HuggingFace's `x-linked-etag`. If this ever
    /// mismatches, the upstream file changed — bump the pin and the user is
    /// forced to re-download. `nil` skips verification with a `Log.warn`
    /// (only acceptable in dev; never ship a spec with `nil` here).
    let expectedSHA256: String?

    /// Tiers this model is willing to serve. `LlamaCppBackend` advertises this
    /// to the router as its `BackendCapability.servesTiers`.
    let servesTiers: Set<ModelTier>

    /// Task kinds this model is good at — nudge for the router.
    let strongAt: Set<InferenceTaskKind>

    /// Router tie-breaker. Lower = preferred when other factors are equal.
    let basePriority: Int

    /// Wraps a user prompt in the model's instruction-tuned chat template.
    /// Getting this wrong silently yields garbled or empty completions —
    /// Gemma uses `<start_of_turn>`/`<end_of_turn>`, Qwen uses
    /// `<|im_start|>`/`<|im_end|>`. `LlamaContext` does NOT auto-detect.
    let chatTemplate: @Sendable (String) -> String

    /// Plain-text stop sequences beyond the model's native EOG token. The
    /// model usually stops itself, but if it ever emits a turn marker as raw
    /// text (vs the control token) these end generation explicitly.
    let extraStopTokens: [String]
}

// MARK: - Known models

extension ModelSpec {
    /// Default generation model. Used for `.medium` rewrites/drafts and the
    /// historical `.small` path before `.classifier` existed.
    static let gemma4E4B_IQ4_XS = ModelSpec(
        id: "bundled/gemma-4-e4b",
        filename: "gemma-4-E4B-it-IQ4_XS.gguf",
        bundleResourceName: "gemma-4-E4B-it-IQ4_XS",
        displayName: "Gemma 4 E4B (IQ4_XS)",
        sourceURL: URL(string:
            "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-IQ4_XS.gguf"
        )!,
        expectedSize: 4_715_414_688,   // ~4.72 GB
        expectedSHA256: "eb29c8519c4c07b880fb9cae7ff13ee2e30c5f38516268920ab85c04df6d52a2",
        // `.classifier` listed as a fallback so classification still works
        // when the dedicated Qwen 0.5B isn't downloaded yet — Qwen's lower
        // `basePriority` (3 vs 5) means the router always prefers it when
        // both are available. Same idea for Apple FM / Ollama capability.
        servesTiers: [.classifier, .small, .medium],
        strongAt: [.classification, .generation],
        basePriority: 5,
        chatTemplate: { p in
            "<start_of_turn>user\n\(p)<end_of_turn>\n<start_of_turn>model\n"
        },
        extraStopTokens: ["<end_of_turn>", "<start_of_turn>"]
    )

    /// Dedicated classification model. ~10× smaller than Gemma, ~10× faster
    /// cold-load, fast enough to make text.paused → popover land in well under
    /// 2 s warm. Used by SentimentGuard and ClarityChecker for the
    /// `.classifier` tier; rewrites/drafts stay on Gemma.
    static let qwen25_05B_Q4_K_M = ModelSpec(
        id: "bundled/qwen2.5-0.5b",
        filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        bundleResourceName: "qwen2.5-0.5b-instruct-q4_k_m",
        displayName: "Qwen 2.5 0.5B (Q4_K_M)",
        sourceURL: URL(string:
            "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
        )!,
        expectedSize: 491_400_032,     // ~491 MB
        expectedSHA256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        servesTiers: [.classifier],
        strongAt: [.classification],
        basePriority: 3,               // preferred over Gemma for classifier tier
        chatTemplate: { p in
            "<|im_start|>user\n\(p)<|im_end|>\n<|im_start|>assistant\n"
        },
        extraStopTokens: ["<|im_end|>", "<|im_start|>"]
    )

    /// Dedicated on-device **compaction** model — Qwen3-4B-Instruct-2507.
    /// A non-thinking instruct model (never emits `<think>` blocks, so output
    /// stays terse), 256K native context for ingesting long transcripts, strong
    /// instruction-following (IFEval ~83), Apache-2.0. Routed to **only** for the
    /// `.compaction` task kind via `strongAt`, so generation/rewrite traffic
    /// stays on Gemma; its higher `basePriority` (6 vs Gemma's 5) keeps Gemma the
    /// winner for `.generation` even though both serve `.medium`.
    ///
    /// Opt-in (~2.5 GB) — unlike Gemma/Qwen-0.5B it is NOT auto-downloaded at
    /// launch (`AppCoordinator.compactionDownloader` is created but not started;
    /// the user triggers it from Settings → Inference). Until it's present,
    /// `.compaction` requests fall back to Gemma. Source is the unsloth GGUF
    /// mirror — the same publisher Halen already trusts for the bundled Gemma.
    /// `expectedSize` / `expectedSHA256` are the file's HuggingFace
    /// `x-linked-size` / `x-linked-etag`.
    static let qwen3_4B_2507_Q4_K_M = ModelSpec(
        id: "bundled/qwen3-4b-2507",
        filename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        bundleResourceName: "Qwen3-4B-Instruct-2507-Q4_K_M",
        displayName: "Qwen3 4B Instruct 2507 (Q4_K_M)",
        sourceURL: URL(string:
            "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        )!,
        expectedSize: 2_497_281_120,   // ~2.50 GB
        expectedSHA256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        servesTiers: [.medium, .large],
        strongAt: [.compaction],
        basePriority: 6,
        chatTemplate: { p in
            "<|im_start|>user\n\(p)<|im_end|>\n<|im_start|>assistant\n"
        },
        extraStopTokens: ["<|im_end|>", "<|im_start|>"]
    )
}
