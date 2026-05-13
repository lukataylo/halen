import Foundation

/// Persistent dictionary of (lowercased-typo → correction) entries with observation counts.
/// A correction is "active" (auto-applied) once it has been observed at least `activeThreshold`
/// times; below that, it's tracked but not applied (gives the user a chance to undo if they
/// changed their mind about the spelling).
///
/// File: `~/Library/Application Support/Halen/typos.json`. Editable by hand.
@MainActor
final class TypoStore {
    struct Entry: Codable, Equatable {
        var correction: String
        var observations: Int
        var firstSeen: Date
        var lastSeen: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private let activeThreshold = 2

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appending(path: "Halen/typos.json")
    }

    init() {
        load()
        seedDemoEntryIfEmpty()
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

    /// On first launch (empty store) seed the owner's known frequent typos so auto-fix
    /// works immediately. The user can edit `typos.json` to add, remove, or tweak entries.
    /// New typos picked up via auto-learn are merged in at runtime.
    private func seedDemoEntryIfEmpty() {
        guard entries.isEmpty else { return }
        let now = Date()
        for (typo, correction) in Self.personalSeed {
            entries[typo] = Entry(
                correction: correction,
                observations: activeThreshold,  // active immediately, no warm-up
                firstSeen: now,
                lastSeen: now
            )
        }
        // Plus a smoke-test entry so the dev can quickly confirm auto-fix is wired up.
        entries["halendemo"] = Entry(
            correction: "HALEN AUTO-LEARN ACTIVE",
            observations: activeThreshold,
            firstSeen: now,
            lastSeen: now
        )
        save()
        Log.info("TypoStore seeded \(entries.count) entries")
    }

    /// The user's known frequent typos. Transposed-adjacent-letter patterns dominate;
    /// also scrambled-vowels and missing-letter cases. Edit the JSON file on disk for
    /// further customization — the seed only applies when the file is empty/absent.
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

        // Missing letters
        "acess": "access",
        "avaition": "aviation",
        "frist": "first",
    ]
}
