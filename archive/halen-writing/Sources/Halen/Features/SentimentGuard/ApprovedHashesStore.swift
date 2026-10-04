import Foundation

/// A persistent, file-backed allowlist of SHA-256 paragraph fingerprints the
/// user has explicitly said "looks fine" to. Pulled out of `SentimentGuard`
/// so the plugin file focuses on the classification + popup flow, with the
/// "did the user already say this is OK?" concern living next to its
/// on-disk representation.
///
/// Persistence shape — a flat `[String]` of hex digests, JSON-encoded for
/// human-diffability. The store is small (one entry per approved paragraph,
/// O(N) approvals over the app's lifetime) so we re-write the file on each
/// mutation; no incremental persistence machinery is needed.
@MainActor
final class ApprovedHashesStore {
    /// The file URL the store reads from / writes to. Each plugin gets its
    /// own slot under `~/Library/Application Support/Halen/<pluginId>/`,
    /// so concurrent stores for sibling plugins don't collide.
    private let fileURL: URL
    /// Plugin id, used as the prefix for log lines (`SentimentGuard:` …)
    /// so log readers can correlate a save failure with the plugin.
    private let logPrefix: String

    private var hashes: Set<String> = []

    init(fileURL: URL, logPrefix: String) {
        self.fileURL = fileURL
        self.logPrefix = logPrefix
        load()
    }

    /// Number of fingerprints currently allowlisted. Surfaced in the
    /// detail-view "approved this session/total" counter.
    var count: Int { hashes.count }

    /// Returns `true` iff `hash` has been previously approved. O(1).
    func contains(_ hash: String) -> Bool { hashes.contains(hash) }

    /// Add `hash` to the allowlist. No-op if already present; otherwise
    /// persists immediately so a crash before the next save still preserves
    /// the user's intent.
    func insert(_ hash: String) {
        let (inserted, _) = hashes.insert(hash)
        if inserted { save() }
    }

    /// Drop every allowlisted hash. The detail-view "Clear allowlist"
    /// button is the one entry point — restores the "re-flag everything"
    /// behaviour of a fresh install.
    func removeAll() {
        guard !hashes.isEmpty else { return }
        hashes.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            // Missing/corrupted file is the first-launch case; the store
            // starts empty and the user re-builds their allowlist by
            // clicking "Looks fine."
            return
        }
        hashes = Set(list)
        Log.info("\(logPrefix): loaded \(hashes.count) approved fingerprints")
    }

    private func save() {
        // Stable order — sorted hex digests diff cleanly in a backup tool.
        let list = hashes.sorted()
        do {
            let data = try JSONEncoder().encode(list)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("\(logPrefix): allowlist save failed — \(error.localizedDescription)")
        }
    }
}
