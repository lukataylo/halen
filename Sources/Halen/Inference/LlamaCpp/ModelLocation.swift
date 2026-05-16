import Foundation

/// Single source of truth for where the bundled-Gemma backend looks for its
/// model file. Two locations, in priority order:
///
///  1. **Downloaded** — `~/Library/Application Support/Halen/Models/<filename>`.
///     Populated by `ModelDownloader` on first use, persists across launches,
///     survives app updates. The default shipping path.
///  2. **Bundled** — `Contents/Resources/Models/<filename>` inside the .app.
///     Only present when `scripts/build-app.sh` was run with `BUNDLE_MODEL=1`
///     (the "all-in-one" build for offline distribution).
///
/// The downloaded copy takes precedence so a user-initiated re-download or a
/// future model update can be picked up without rebuilding the app.
enum ModelLocation {
    /// Canonical filename. Matches the source HuggingFace asset
    /// (`unsloth/gemma-4-E4B-it-GGUF`).
    static let filename = "gemma-4-E4B-it-Q4_K_M.gguf"

    /// Best-available URL for the GGUF, or `nil` if neither location has it
    /// (fresh install on a Mac without Apple Intelligence — `ModelDownloader`
    /// must be invoked).
    static var resolved: URL? {
        if let downloaded, FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        return bundled
    }

    /// Target path for `ModelDownloader`. Always returns a valid URL — the file
    /// may or may not exist on disk yet.
    static var downloaded: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appending(path: "Halen", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: filename)
    }

    /// `Contents/Resources/Models/<filename>` inside the .app — only present in
    /// `BUNDLE_MODEL=1` builds. `nil` in the default slim build.
    static var bundled: URL? {
        Bundle.main.url(forResource: "gemma-4-E4B-it-Q4_K_M",
                        withExtension: "gguf",
                        subdirectory: "Models")
    }

    /// True iff a bundled-Gemma model is available somewhere on disk (either
    /// downloaded or bundled).
    static var isAvailable: Bool { resolved != nil }
}
