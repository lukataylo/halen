import Foundation

/// Resolves Halen's user-data directory once and exposes a single safe entry
/// point everything else builds on (`HalenServices.appSupportDir`, plugin
/// scratch dirs, the typo store, the per-app tone profile store, etc.).
///
/// Pre-extraction, three call sites force-unwrapped
/// `FileManager.default.urls(for: .applicationSupportDirectory, …).first` —
/// macOS *should* provide it for any signed app, but a sandboxed or
/// fileproviderless context could return an empty list, which would trap
/// the whole process on startup. This file is the single guarded resolver:
/// the canonical path is the OS Application Support; if for any reason the
/// OS doesn't hand one over, we fall back to a deterministic location in
/// `NSTemporaryDirectory()`, log loudly, and the app keeps running with
/// non-persistent state instead of crashing.
enum HalenSupportDirectory {
    /// `~/Library/Application Support/Halen/` — created if missing.
    /// Returns the temp-dir fallback when Application Support is somehow
    /// unavailable (vanishingly rare; logged at `.error` if it happens).
    static let root: URL = {
        let fm = FileManager.default
        let candidate: URL
        if let support = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first {
            candidate = support.appending(path: "Halen")
        } else {
            // Deterministic fallback so two calls in the same session land in
            // the same place. `NSTemporaryDirectory()` is process-local, so
            // data won't persist across restarts — but a crashing app
            // wouldn't persist either, and this lets the user actually use
            // Halen until they fix whatever broke their Application Support.
            let temp = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true)
            candidate = temp.appending(path: "Halen")
            Log.error("HalenSupportDirectory: Application Support unavailable — falling back to \(candidate.path)")
        }
        do {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        } catch {
            Log.error("HalenSupportDirectory: createDirectory failed for \(candidate.path) — \(error.localizedDescription)")
        }
        return candidate
    }()

    /// `root/<subpath>` with the directory created on first call.
    /// Used by plugin storage, the model downloader, and the rule stores.
    static func subdirectory(_ subpath: String) -> URL {
        let url = root.appending(path: subpath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
