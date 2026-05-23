import Foundation

/// Where the MLX backend's weights come from and where they land on disk.
///
/// Unlike the llama.cpp backend (a single hand-pinned `.gguf` fetched by
/// Halen's own `ModelDownloader`), MLX models are multi-file repos —
/// `config.json`, tokenizer files, and sharded `*.safetensors` weights.
/// The `mlx-swift` `Hub` client handles fetching the whole repo and caching
/// it; Halen only needs to name the repo and the cache root.
///
/// The chosen repo is a 4-bit MLX conversion of the same Gemma 4 E4B model
/// the bundled-llama backend runs, so the two backends are quality-comparable
/// and the router can treat them as interchangeable for the `.medium` tier.
enum MLXModelLocation {
    /// HuggingFace repo id for the MLX-format weights.
    ///
    /// NOTE: confirm the exact repo id on HuggingFace before first run — the
    /// `mlx-community` org publishes the canonical conversions and the naming
    /// of the Gemma 4 E4B 4-bit variant should be verified there. This is the
    /// expected id; adjust if the published artifact differs.
    static let repoId = "mlx-community/gemma-4-E4B-it-4bit"

    /// Cache root for downloaded MLX repos. Kept under Halen's Application
    /// Support dir (sibling of the llama.cpp `Models/` folder) so a user
    /// clearing Halen's data reclaims both runtimes' weights in one place.
    static var cacheDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appending(path: "Halen", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "mlx", directoryHint: .isDirectory)
    }

    /// True iff the repo appears to be present in the cache. A real readiness
    /// check belongs in the `Hub` client (it knows the manifest); this is the
    /// cheap "has anything been downloaded" probe for `availability()`.
    static var isCached: Bool {
        guard let dir = cacheDirectory else { return false }
        let repoPath = dir.appending(path: repoId.replacingOccurrences(of: "/", with: "--"))
        return FileManager.default.fileExists(atPath: repoPath.path)
    }
}
