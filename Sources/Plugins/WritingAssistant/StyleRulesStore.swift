import Foundation
import Observation

/// How a rule's `banned` field is matched against text.
///   - `literal` (the default): case-insensitive substring match with word
///     boundaries. The shipping behaviour from day one.
///   - `regex`: NSRegularExpression with `.caseInsensitive` enabled.
///     Lets power users write `\bcolou?r\b` for spelling variants or
///     `[Tt]eam\s+ABC` for trademarks.
enum StyleRuleKind: String, Codable, Sendable, CaseIterable {
    case literal, regex
}

/// One personal-style rule. `banned` is the term to flag; `preferred` is the
/// replacement, or empty for a pure "never use this" prohibition. Built-in
/// rules can be toggled but not deleted; custom rules both. `kind` defaults
/// to `.literal` for backward compatibility with rules written before regex
/// support landed.
struct StyleRule: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let banned: String
    let preferred: String
    var enabled: Bool
    let builtin: Bool
    /// Optional in JSON so older `rules.json` files load without a wipe.
    /// Decode falls back to `.literal` (the only behaviour that existed
    /// before this field was introduced).
    var kind: StyleRuleKind = .literal

    /// True when there's no replacement — the rule just says "don't use this".
    var isProhibition: Bool {
        preferred.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Custom decoder so the `kind` key being absent (older payloads) maps
    /// to `.literal`. Synthesised Decodable would treat the missing key as
    /// an error and fail the whole load.
    private enum CodingKeys: String, CodingKey {
        case id, banned, preferred, enabled, builtin, kind
    }
    init(id: String, banned: String, preferred: String,
         enabled: Bool, builtin: Bool, kind: StyleRuleKind = .literal) {
        self.id = id
        self.banned = banned
        self.preferred = preferred
        self.enabled = enabled
        self.builtin = builtin
        self.kind = kind
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        banned = try c.decode(String.self, forKey: .banned)
        preferred = try c.decode(String.self, forKey: .preferred)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        builtin = try c.decode(Bool.self, forKey: .builtin)
        kind = (try? c.decode(StyleRuleKind.self, forKey: .kind)) ?? .literal
    }
}

/// One hit from scanning text against the style rules.
struct StyleMatch: Identifiable {
    let id = UUID().uuidString
    let rule: StyleRule
    /// The text as it actually appeared (preserves the user's casing).
    let matchedText: String
}

/// JSON-backed, `@Observable` store of personal-style rules. A pure rule
/// engine — no inference, so scanning is instant and 100% deterministic.
/// Load/save/slug plumbing lives in `JSONRuleStoreSupport`.
@Observable
@MainActor
final class StyleRulesStore {
    private(set) var rules: [StyleRule] = []

    private let fileURL: URL
    private static let storeName = "StyleRulesStore"

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let loaded = JSONRuleStoreSupport.load(
            StyleRule.self, from: fileURL, storeName: Self.storeName) {
            rules = loaded
        }
        ensureDefaults()
    }

    /// A few widely-agreed defaults so the plugin does something out of the
    /// box; everything personal is added by the user.
    static let builtins: [StyleRule] = [
        .init(id: "utilize", banned: "utilize", preferred: "use", enabled: true, builtin: true),
        .init(id: "very_unique", banned: "very unique", preferred: "unique", enabled: true, builtin: true),
        .init(id: "irregardless", banned: "irregardless", preferred: "regardless", enabled: true, builtin: true),
    ]

    // MARK: - Mutations

    func setEnabled(_ id: String, enabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled = enabled
        save()
    }

    func addCustomRule(banned: String, preferred: String,
                       kind: StyleRuleKind = .literal) {
        let trimmedBanned = banned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBanned.isEmpty else { return }
        // Regex rules are validated up-front — a bad pattern would silently
        // never match at scan time, looking like a Halen bug. Reject the add
        // and log; the detail view checks the same predicate before enabling
        // the Add button to surface the error inline.
        if kind == .regex && !Self.isValidRegex(trimmedBanned) {
            Log.warn("\(Self.storeName): rejected invalid regex \"\(trimmedBanned)\"")
            return
        }
        rules.append(StyleRule(
            id: JSONRuleStoreSupport.slugId(from: trimmedBanned) + "_\(kind.rawValue)",
            banned: trimmedBanned,
            preferred: preferred.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: true, builtin: false, kind: kind))
        save()
        Log.info("\(Self.storeName): added custom \(kind.rawValue) rule \"\(trimmedBanned)\"")
    }

    /// CSV import. Format: `banned,preferred[,kind]` per line, header row
    /// optional (it's detected and skipped if the first row matches the
    /// known column names). Empty lines are tolerated; rows with fewer than
    /// 2 columns are skipped with a log line. `kind` defaults to `literal`
    /// when absent or unrecognised.
    ///
    /// Returns (imported, skipped) so the detail view can show a toast.
    @discardableResult
    func importCSV(_ csv: String) -> (imported: Int, skipped: Int) {
        var imported = 0, skipped = 0
        let lines = csv.split(whereSeparator: \.isNewline)
        for (idx, raw) in lines.enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Skip the header row when it looks like one.
            if idx == 0, cols.count >= 2,
               cols[0].lowercased() == "banned" {
                continue
            }
            guard cols.count >= 2 else { skipped += 1; continue }
            let kindRaw = cols.count >= 3 ? cols[2].lowercased() : "literal"
            let kind = StyleRuleKind(rawValue: kindRaw) ?? .literal
            addCustomRule(banned: cols[0], preferred: cols[1], kind: kind)
            imported += 1
        }
        Log.info("\(Self.storeName): CSV import imported=\(imported) skipped=\(skipped)")
        return (imported, skipped)
    }

    /// Up-front validation for regex rules. Cheap; runs at add time only,
    /// not in the hot scan path.
    private static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }

    func remove(_ id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }), !rules[idx].builtin else { return }
        rules.remove(at: idx)
        save()
    }

    var sorted: [StyleRule] {
        rules.sorted { lhs, rhs in
            if lhs.builtin != rhs.builtin { return lhs.builtin && !rhs.builtin }
            return lhs.banned.lowercased() < rhs.banned.lowercased()
        }
    }

    var enabledRules: [StyleRule] { rules.filter(\.enabled) }

    // MARK: - Scanning

    /// Scan `text` for the first occurrence of each enabled rule's banned term.
    /// Word-boundary aware for literal rules so "use" doesn't match inside
    /// "user"; regex rules honour their own pattern as written.
    func scan(_ text: String) -> [StyleMatch] {
        let ns = text as NSString
        var out: [StyleMatch] = []
        for rule in enabledRules {
            let range: NSRange?
            switch rule.kind {
            case .literal:
                range = Self.wordRange(of: rule.banned, in: ns)
            case .regex:
                range = Self.firstRegexMatch(pattern: rule.banned, in: ns)
            }
            if let r = range {
                out.append(StyleMatch(rule: rule, matchedText: ns.substring(with: r)))
            }
        }
        return out
    }

    /// First case-insensitive regex match anywhere in `ns`, or nil. Treats a
    /// bad pattern as no-match (validation at add time keeps these from
    /// reaching production, but we degrade gracefully if a hand-edited
    /// rules.json ships a broken regex).
    static func firstRegexMatch(pattern: String, in ns: NSString) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let m = re.firstMatch(in: ns as String, options: [],
                              range: NSRange(location: 0, length: ns.length))
        guard let m, m.range.location != NSNotFound else { return nil }
        return m.range
    }

    /// First word-boundary-respecting occurrence of `term` in `ns`, or nil.
    static func wordRange(of term: String, in ns: NSString) -> NSRange? {
        guard !term.isEmpty else { return nil }
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(of: term, options: [.caseInsensitive],
                                 range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard found.location != NSNotFound else { return nil }
            let before: unichar? = found.location > 0 ? ns.character(at: found.location - 1) : nil
            let afterIdx = found.location + found.length
            let after: unichar? = afterIdx < ns.length ? ns.character(at: afterIdx) : nil
            if !Self.isLetter(before) && !Self.isLetter(after) { return found }
            searchStart = found.location + max(1, found.length)
        }
        return nil
    }

    private static func isLetter(_ c: unichar?) -> Bool {
        guard let c, let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    // MARK: - Persistence

    private func ensureDefaults() {
        let existing = Set(rules.map(\.id))
        var changed = false
        for rule in Self.builtins where !existing.contains(rule.id) {
            rules.append(rule)
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        JSONRuleStoreSupport.save(rules, to: fileURL, storeName: Self.storeName)
    }
}
