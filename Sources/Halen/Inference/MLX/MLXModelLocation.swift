import Foundation

/// Where the MLX backend's weights come from and where they land on disk.
///
/// Unlike the llama.cpp backend (a single hand-pinned `.gguf` fetched by
/// Halen's own `ModelDownloader`), MLX models are multi-file repos —
/// `config.json`, tokenizer files, and sharded `*.safetensors` weights.
/// The `mlx-swift` `Hub` client handles fetching the whole repo and caching
/// it; Halen only needs to name the repo and the cache root.
///
/// Set to the same Qwen 2.5 0.5B Instruct model the llama.cpp classifier
/// backend uses, just in MLX's `safetensors` format. Lets the router treat
/// the two `.classifier`-tier backends as quality-comparable so we can
/// benchmark MLX-vs-llama.cpp on identical work and promote the faster
/// path. The mlx-community 4-bit conversion is the canonical MLX build.
enum MLXModelLocation {
    /// HuggingFace repo id for the MLX-format Qwen 2.5 0.5B Instruct weights.
    /// Confirmed in `mlx-community`; the 4-bit AWQ quant is ~150 MB on disk.
    static let repoId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

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
