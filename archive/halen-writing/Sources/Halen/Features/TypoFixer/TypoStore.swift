import Foundation
import Observation

/// Persistent dictionary of (lowercased-typo → correction) entries with observation counts.
/// A correction is "active" (auto-applied) once it has been observed at least `activeThreshold`
/// times; below that, it's tracked but not applied (gives the user a chance to undo if they
/// changed their mind about the spelling).
///
/// File: `~/Library/Application Support/Halen/typos.json`. Editable by hand.
@Observable
@MainActor
final class TypoStore {
    struct Entry: Codable, Equatable {
        var correction: String
        var observations: Int
        var firstSeen: Date
        var lastSeen: Date
    }

    private(set) var entries: [String: Entry] = [:]

    /// How many times a (typo → correction) pair has to be observed before
    /// Halen will auto-apply it. 1 = aggressive (first time is enough),
    /// 5 = conservative (five confirmations). The detail view exposes this
    /// as a slider; user-added entries skip the warm-up regardless (they
    /// land with `observations == activeThreshold` from the start).
    static let activeThresholdKey = "halen.typoFixer.activeThreshold"
    static let activeThresholdDefault = 2
    static let activeThresholdRange = 1...5

    /// Live-read from defaults. Cheap (single integer lookup); not cached
    /// so a slider drag in Settings takes effect on the next keystroke
    /// without anyone having to invalidate state.
    var activeThreshold: Int {
        let raw = UserDefaults.standard.object(forKey: Self.activeThresholdKey) as? Int
        return raw.flatMap { Self.activeThresholdRange.contains($0) ? $0 : nil }
            ?? Self.activeThresholdDefault
    }

    static var fileURL: URL {
        HalenSupportDirectory.root.appending(path: "typos.json")
    }

    init() {
        load()
        ensureSeedEntries()
    }

    /// Returns the correction if the entry exists and has been confirmed (observations ≥ threshold).
    func activeCorrection(for typo: String) -> String? {
        guard let entry = entries[typo.lowercased()], entry.observations >= activeThreshold else {
            return nil
        }
        return entry.correction
    }

    /// Increment an existing entry or create a new one. If a different correction is recorded
    /// for the same typo, the new one supersedes the old (and observations reset to 1).
    func observe(typo: String, correction: String) {
        let key = typo.lowercased()
        let now = Date()
        if var existing = entries[key] {
            if existing.correction == correction {
                existing.observations += 1
            } else {
                existing.correction = correction
                existing.observations = 1
            }
            existing.lastSeen = now
            entries[key] = existing
        } else {
            entries[key] = Entry(
                correction: correction,
                observations: 1,
                firstSeen: now,
                lastSeen: now
            )
        }
        save()
    }

    func reset() {
        entries.removeAll()
        save()
        Log.info("TypoStore reset")
    }

    /// User-driven addition from the management UI. The new entry is active immediately.
    func addUserEntry(typo: String, correction: String) {
        let key = typo.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        let now = Date()
        entries[key] = Entry(
            correction: value,
            observations: activeThreshold,
            firstSeen: entries[key]?.firstSeen ?? now,
            lastSeen: now
        )
        save()
        Log.info("TypoStore: user added \"\(key)\" → \"\(value)\"")
    }

    /// User-driven removal from the management UI.
    func remove(typo: String) {
        let key = typo.lowercased()
        if entries.removeValue(forKey: key) != nil {
            save()
            Log.info("TypoStore: user removed \"\(key)\"")
        }
    }

    /// Sorted view of entries, freshest first. Drives the management list.
    var sortedEntries: [(key: String, entry: Entry)] {
        entries.map { ($0.key, $0.value) }.sorted { $0.entry.lastSeen > $1.entry.lastSeen }
    }

    /// Remove an entry — used by `TypoFixer` when the user immediately reverts an
    /// auto-fix, indicating the correction was wrong (typically a context-dependent
    /// homophone like form↔from).
    func demote(typo: String) {
        let key = typo.lowercased()
        if entries.removeValue(forKey: key) != nil {
            save()
            Log.info("TypoStore demoted \"\(key)\"")
        }
    }

    // MARK: - Persistence

    private struct FilePayload: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private func load() {
        do {
            let data = try Data(contentsOf: Self.fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(FilePayload.self, from: data)
            entries = payload.entries
            Log.info("TypoStore loaded \(entries.count) entries")
        } catch {
            Log.debug("TypoStore: no existing file (will create on first save)")
        }
    }

    private func save() {
        do {
            let payload = FilePayload(version: 1, entries: entries)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.error("TypoStore save failed: \(error.localizedDescription)")
        }
    }

    /// Merge `personalSeed` into the store. Existing entries (either seeded earlier
    /// or auto-learned) are left untouched — only missing keys are added. Runs every
    /// launch so new entries added to `personalSeed` ship without requiring a reset.
    /// Removing an entry from `personalSeed` doesn't delete it from the user's store;
    /// they should edit `typos.json` directly for that.
    private func ensureSeedEntries() {
        var addedKeys: [String] = []
        let now = Date()

        for (typo, correction) in Self.personalSeed where entries[typo] == nil {
            entries[typo] = Entry(
                correction: correction,
                observations: activeThreshold,  // active immediately, no warm-up
                firstSeen: now,
                lastSeen: now
            )
            addedKeys.append(typo)
        }

        if !addedKeys.isEmpty {
            save()
            Log.info("TypoStore seeded \(addedKeys.count) new entries; total \(entries.count)")
        } else {
            Log.info("TypoStore loaded \(entries.count) entries (seed up to date)")
        }
    }

    /// The user's known frequent typos. Edit `typos.json` directly for runtime changes;
    /// the seed only adds keys that aren't already present.
    ///
    /// NOTE on context-dependent entries (`form`, `sweet`, `creative`, `complements`,
    /// `hardboard`): these are real words with legitimate uses, not typos. Auto-fix
    /// will misfire on legitimate usages. The `TypoFixer` revert-on-undo mechanism
    /// removes an entry the first time the user backspaces and retypes the original
    /// within 60s of an auto-fix, so misfires are self-correcting after one occurrence.
    /// The proper fix is the M2 LLM context check.
    private static let personalSeed: [String: String] = [
        // Transposed adjacent letters
        "udnerstand": "understand",
        "udpate": "update",
        "rneder": "render",
        "indvidual": "individual",
        "exlcusion": "exclusion",
        "applciation": "application",
        "bullepointed": "bulletpointed",

        // Scrambled vowels mid-word
        "weleocme": "welcome",
        "extreamly": "extremely",
        "creriera": "criteria",
        "prioroirty": "priority",
        "conditoianls": "conditionals",
        "conssitency": "consistency",

        "alot": "a lot",

        // Missing letters
        "acess": "access",
        "avaition": "aviation",
        "frist": "first",

        // Homophones / sound-alikes (context-dependent — see note above)
        "loosing": "losing",
        "complements": "compliments",
        "form": "from",
        "sweet": "suite",

        // Word substitutions (adjacent concept slipped in; context-dependent)
        "creative": "create",
        "hardboard": "artboard",
        "precendent": "precedent",

        // Run-on / missing-space compounds
        "littlebit": "a little bit",
        "msyelf": "myself",
        // "alot": "a lot" already in original seed above

        // Extra/double letters mid-word
        "scenrarios": "scenarios",
        "reportingd": "reporting",
        "whhats": "whats",
        "tyring": "trying",
        "desperatley": "desperately",
    ]
}
