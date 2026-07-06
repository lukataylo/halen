import Foundation
import HalenPluginAPI
import Observation

// Mother's config + ledger persistence. Ported byte-compatible from the
// Python plugin: same directory (`~/Library/Application Support/Halen/
// com.halen.mother/`, mapped by the host via `context.storage.directory`),
// same file names (`config.json`, `state.json`), same JSON schemas — so an
// existing user's rulebook and violation history survive the port intact.

// MARK: - Config model

/// One entry of `blockedApps`. Wire shape: `{"bundleId": "...", "name": "..."}`.
struct MotherBlockedApp: Codable, Equatable, Sendable, Identifiable {
    var bundleId: String
    var name: String

    var id: String { bundleId }

    private enum CodingKeys: String, CodingKey { case bundleId, name }

    init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }

    /// Lenient like the Python `entry.get(...)`: a missing `name` falls back
    /// to the bundle id, a missing `bundleId` becomes an entry that never
    /// matches (Python's `entry.get("bundleId") == bundle_id` with None).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = ((try? c.decodeIfPresent(String.self, forKey: .bundleId)) ?? nil) ?? ""
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? bundleId
    }
}

/// One entry of `focusHours`. Wire shape:
/// `{"days": [0,1,2,3,4], "start": "09:00", "end": "18:00"}` — days use
/// 0=Mon … 6=Sun, times are local 24h "HH:MM".
struct MotherFocusWindow: Codable, Equatable, Sendable {
    var days: [Int]
    var start: String
    var end: String

    private enum CodingKeys: String, CodingKey { case days, start, end }

    init(days: [Int], start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }

    /// Same defaults the Python `in_focus_hours` applied at read time:
    /// missing days = every day, missing start/end = the whole day.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = ((try? c.decodeIfPresent([Int].self, forKey: .days)) ?? nil) ?? [0, 1, 2, 3, 4, 5, 6]
        start = ((try? c.decodeIfPresent(String.self, forKey: .start)) ?? nil) ?? "00:00"
        end = ((try? c.decodeIfPresent(String.self, forKey: .end)) ?? nil) ?? "23:59"
    }
}

/// The effective strictness right now, folding the schedule in. Mirrors the
/// Python `current_mode()` return values 'off' / 'warn' /
/// 'enforce-no-override' / 'enforce-override'.
enum MotherMode: Equatable, Sendable {
    case off
    case warn
    case enforceNoOverride
    case enforceOverride
}

/// Mother's rulebook — `config.json`. Field names and value shapes match the
/// Python plugin's DEFAULT_CONFIG exactly, including the leading `_comment`.
struct MotherConfig: Codable, Equatable, Sendable {
    var comment: String
    var enforcement: String
    var graceSeconds: Double
    var sitePollSeconds: Double
    var confrontTimeoutSeconds: Double
    var overrideMinutes: Double
    var focusHours: [MotherFocusWindow]
    var blockedApps: [MotherBlockedApp]
    var blockedSites: [String]

    private enum CodingKeys: String, CodingKey {
        case comment = "_comment"
        case enforcement, graceSeconds, sitePollSeconds
        case confrontTimeoutSeconds, overrideMinutes
        case focusHours, blockedApps, blockedSites
    }

    /// Verbatim copy of the Python DEFAULT_CONFIG, seeded on first run.
    /// The default blocklist is pure-distraction apps only — work-critical
    /// chat apps (Slack, Discord) are deliberately NOT here: quitting an
    /// Electron chat app can discard a half-typed message, and a fresh
    /// install must never lose the user's data before they've opted in.
    static let `default` = MotherConfig(
        comment: "Mother's local rulebook. Edit freely; she reloads it whenever the "
            + "file changes. enforcement: 'off' | 'soft' | 'hardcore' | 'lockdown' "
            + "(an unrecognized value is treated as 'soft', never escalated). "
            + "focusHours.days use 0=Mon ... 6=Sun. Times are local 24h 'HH:MM'.",
        enforcement: "hardcore",
        graceSeconds: 6,
        sitePollSeconds: 3,
        confrontTimeoutSeconds: 45,
        overrideMinutes: 5,
        focusHours: [MotherFocusWindow(days: [0, 1, 2, 3, 4], start: "09:00", end: "18:00")],
        blockedApps: [
            MotherBlockedApp(bundleId: "ru.keepcoder.Telegram", name: "Telegram"),
            MotherBlockedApp(bundleId: "com.zhiliaoapp.musically", name: "TikTok"),
            MotherBlockedApp(bundleId: "com.netflix.Netflix", name: "Netflix"),
            MotherBlockedApp(bundleId: "com.valvesoftware.steam", name: "Steam"),
            MotherBlockedApp(bundleId: "com.reddit.reddit", name: "Reddit"),
        ],
        blockedSites: [
            "x.com", "twitter.com", "reddit.com", "youtube.com", "tiktok.com",
            "instagram.com", "facebook.com", "netflix.com", "news.ycombinator.com",
        ])

    init(comment: String, enforcement: String, graceSeconds: Double,
         sitePollSeconds: Double, confrontTimeoutSeconds: Double,
         overrideMinutes: Double, focusHours: [MotherFocusWindow],
         blockedApps: [MotherBlockedApp], blockedSites: [String]) {
        self.comment = comment
        self.enforcement = enforcement
        self.graceSeconds = graceSeconds
        self.sitePollSeconds = sitePollSeconds
        self.confrontTimeoutSeconds = confrontTimeoutSeconds
        self.overrideMinutes = overrideMinutes
        self.focusHours = focusHours
        self.blockedApps = blockedApps
        self.blockedSites = blockedSites
    }

    /// Per-key lenient decode, replicating Python's
    /// `merged = dict(DEFAULT_CONFIG); merged.update({k: v ... if v is not None})`:
    /// a missing / null / wrong-typed key keeps its default instead of
    /// failing the whole document.
    init(from decoder: Decoder) throws {
        let d = MotherConfig.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
        }
        comment = field(.comment, d.comment)
        enforcement = field(.enforcement, d.enforcement)
        graceSeconds = field(.graceSeconds, d.graceSeconds)
        sitePollSeconds = field(.sitePollSeconds, d.sitePollSeconds)
        confrontTimeoutSeconds = field(.confrontTimeoutSeconds, d.confrontTimeoutSeconds)
        overrideMinutes = field(.overrideMinutes, d.overrideMinutes)
        focusHours = field(.focusHours, d.focusHours)
        blockedApps = field(.blockedApps, d.blockedApps)
        blockedSites = field(.blockedSites, d.blockedSites)
    }

    // MARK: Schedule

    /// "HH:MM" → minute of day, nil when malformed. Port of `_parse_hm`.
    static func parseHM(_ s: String) -> Int? {
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let h = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let m = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return h * 60 + m
    }

    /// True if the local time falls inside any configured focus window. An
    /// entry whose end <= start is treated as spanning midnight.
    func inFocusHours(at date: Date = Date()) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = comps.hour, let minute = comps.minute, let wd = comps.weekday else {
            return false
        }
        let minuteOfDay = hour * 60 + minute
        let weekday = (wd + 5) % 7  // Calendar: 1=Sun … 7=Sat → 0=Mon … 6=Sun
        for window in focusHours {
            guard window.days.contains(weekday),
                  let start = Self.parseHM(window.start),
                  let end = Self.parseHM(window.end)
            else { continue }
            if start <= end {
                if start <= minuteOfDay && minuteOfDay < end { return true }
            } else {  // wraps past midnight
                if minuteOfDay >= start || minuteOfDay < end { return true }
            }
        }
        return false
    }

    /// True when `enforcement` is one of the strings the rulebook documents.
    var enforcementIsRecognized: Bool {
        switch enforcement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "disabled", "none", "soft", "hardcore", "lockdown": return true
        default: return false
        }
    }

    /// Port of `current_mode()`. An unrecognized enforcement value fails SAFE
    /// — to the least destructive mode — never silently escalated to
    /// hardcore. A config mistake must not be a data-loss event.
    func effectiveMode(at date: Date = Date()) -> MotherMode {
        switch enforcement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "disabled", "none":
            return .off
        case "soft":
            return .warn
        case "lockdown":
            return .enforceNoOverride
        case "hardcore":
            // relentless during focus hours, negotiable (with friction) outside
            return inFocusHours(at: date) ? .enforceNoOverride : .enforceOverride
        default:
            return .warn
        }
    }
}

// MARK: - Ledger model

/// One ledger entry. Wire shape:
/// `{"ts": <epoch>, "iso": "...", "kind": "app"|"site", "target": "...", "action": "..."}`.
struct MotherViolation: Codable, Equatable, Sendable {
    var ts: Double
    var iso: String
    var kind: String
    var target: String
    var action: String

    private enum CodingKeys: String, CodingKey { case ts, iso, kind, target, action }

    init(ts: Double, iso: String, kind: String, target: String, action: String) {
        self.ts = ts
        self.iso = iso
        self.kind = kind
        self.target = target
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
        }
        ts = field(.ts, 0)
        iso = field(.iso, "")
        kind = field(.kind, "")
        target = field(.target, "")
        action = field(.action, "")
    }
}

/// Mother's local ledger — `state.json`. Every violation and every override
/// you talked her into, plus running totals. Nothing leaves the Mac.
struct MotherState: Codable, Equatable, Sendable {
    var installedAt: Double
    var violations: [MotherViolation]
    var overrides: Int
    var totalQuits: Int
    var totalTabsClosed: Int

    private enum CodingKeys: String, CodingKey {
        case installedAt, violations, overrides, totalQuits, totalTabsClosed
    }

    init(installedAt: Double = Date().timeIntervalSince1970,
         violations: [MotherViolation] = [],
         overrides: Int = 0, totalQuits: Int = 0, totalTabsClosed: Int = 0) {
        self.installedAt = installedAt
        self.violations = violations
        self.overrides = overrides
        self.totalQuits = totalQuits
        self.totalTabsClosed = totalTabsClosed
    }

    /// Lenient like Python's `.get(...)` counters — an older or hand-edited
    /// state file with missing keys loads instead of being reset.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
        }
        installedAt = field(.installedAt, Date().timeIntervalSince1970)
        violations = field(.violations, [])
        overrides = field(.overrides, 0)
        totalQuits = field(.totalQuits, 0)
        totalTabsClosed = field(.totalTabsClosed, 0)
    }
}

// MARK: - Store

/// Owns `config.json` + `state.json` in the plugin's storage directory.
/// `@Observable` so the detail view re-renders on edits and on hot reloads.
///
/// Files are read/written with FileManager directly (not
/// `StorageService.readJSON/writeJSON`) so the file names and failure
/// semantics stay byte-identical to the Python plugin: seed on missing,
/// keep-last-good on corrupt, atomic replace on write.
@Observable
@MainActor
final class MotherConfigStore {
    private(set) var config: MotherConfig = .default
    private(set) var state: MotherState = MotherState()

    private let directory: URL
    /// mtime of the last successfully loaded config; reload is skipped while
    /// it hasn't moved (the Python `_config_mtime` check).
    private var configModified: Date?

    var configURL: URL { directory.appending(path: "config.json") }
    var stateURL: URL { directory.appending(path: "state.json") }

    init(directory: URL) {
        self.directory = directory
        reloadConfigIfChanged()
        loadState()
    }

    // MARK: Config

    /// Read config.json, seeding defaults on first run. Cheap to call often;
    /// only re-parses when the file's mtime moves. Port of `load_config()`.
    func reloadConfigIfChanged() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: configURL.path),
              let mtime = attrs[.modificationDate] as? Date
        else {
            seedDefaultConfig()
            return
        }
        if let known = configModified, known == mtime { return }
        guard let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode(MotherConfig.self, from: data)
        else {
            Log.warn("Mother: config unreadable, keeping last good copy")
            return
        }
        config = loaded
        configModified = mtime
        Log.info("Mother: loaded config — enforcement=\(loaded.enforcement), "
            + "\(loaded.blockedApps.count) app(s), \(loaded.blockedSites.count) site(s)")
    }

    private func seedDefaultConfig() {
        config = .default
        writeConfigFile(mergingUnknownKeys: false)
        Log.info("Mother: seeded default config.json")
    }

    /// Mutate the config from the UI and persist it. Unknown top-level keys a
    /// user added by hand to config.json are preserved across the write.
    func update(_ mutate: (inout MotherConfig) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        config = next
        writeConfigFile(mergingUnknownKeys: true)
    }

    private func writeConfigFile(mergingUnknownKeys: Bool) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(config)
            guard var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
            if mergingUnknownKeys,
               let existingData = try? Data(contentsOf: configURL),
               let existing = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] {
                // Keys this build doesn't model ride along untouched.
                for (key, value) in existing where dict[key] == nil {
                    dict[key] = value
                }
            }
            let out = try JSONSerialization.data(withJSONObject: dict,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: configURL, options: .atomic)
            let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path)
            configModified = attrs?[.modificationDate] as? Date
        } catch {
            Log.warn("Mother: could not persist config (\(error.localizedDescription))")
        }
    }

    // MARK: Ledger

    private func loadState() {
        if let data = try? Data(contentsOf: stateURL),
           let loaded = try? JSONDecoder().decode(MotherState.self, from: data) {
            state = loaded
            return
        }
        state = MotherState()
        saveState()
    }

    /// Local-time ISO stamp with seconds precision, matching Python's
    /// `datetime.now().isoformat(timespec="seconds")` (no timezone suffix).
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Append a violation to the local ledger (last 500 kept). Port of `record()`.
    func record(kind: String, target: String, action: String) {
        let now = Date()
        state.violations.append(MotherViolation(
            ts: now.timeIntervalSince1970,
            iso: Self.isoFormatter.string(from: now),
            kind: kind, target: target, action: action))
        if state.violations.count > 500 {
            state.violations.removeFirst(state.violations.count - 500)
        }
        switch action {
        case "quit": state.totalQuits += 1
        case "closed-tab": state.totalTabsClosed += 1
        case "override": state.overrides += 1
        default: break
        }
        saveState()
    }

    private func saveState() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Log.warn("Mother: could not persist state (\(error.localizedDescription))")
        }
    }
}
