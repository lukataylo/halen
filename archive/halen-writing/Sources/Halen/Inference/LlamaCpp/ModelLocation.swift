import Foundation

/// Resolves on-disk paths for a `ModelSpec`. Two locations, in priority order:
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
    /// Best-available URL for `spec`'s GGUF, or `nil` if neither location has
    /// it (fresh install — `ModelDownloader` must be invoked).
    static func resolved(for spec: ModelSpec) -> URL? {
        if let downloaded = downloaded(for: spec),
           FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        return bundled(for: spec)
    }

    /// Target path for `ModelDownloader`. Always returns a valid URL — the
    /// file may or may not exist on disk yet.
    static func downloaded(for spec: ModelSpec) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appending(path: "Halen", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: spec.filename)
    }

    /// `Contents/Resources/Models/<filename>` inside the .app — only present
    /// in `BUNDLE_MODEL=1` builds. `nil` in the default slim build.
    static func bundled(for spec: ModelSpec) -> URL? {
        Bundle.main.url(forResource: spec.bundleResourceName,
                        withExtension: "gguf",
                        subdirectory: "Models")
    }

    /// True iff `spec`'s GGUF is available somewhere on disk (downloaded or
    /// bundled).
    static func isAvailable(for spec: ModelSpec) -> Bool { resolved(for: spec) != nil }
}
