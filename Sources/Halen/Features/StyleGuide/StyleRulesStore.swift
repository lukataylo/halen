import Foundation
import Observation

/// One personal-style rule. `banned` is the term to flag; `preferred` is the
/// replacement, or empty for a pure "never use this" prohibition. Built-in
/// rules can be toggled but not deleted; custom rules both.
struct StyleRule: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let banned: String
    let preferred: String
    var enabled: Bool
    let builtin: Bool

    /// True when there's no replacement — the rule just says "don't use this".
    var isProhibition: Bool {
        preferred.trimmingCharacters(in: .whitespaces).isEmpty
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

    func addCustomRule(banned: String, preferred: String) {
        let trimmedBanned = banned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBanned.isEmpty else { return }
        rules.append(StyleRule(
            id: JSONRuleStoreSupport.slugId(from: trimmedBanned),
            banned: trimmedBanned,
            preferred: preferred.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: true, builtin: false))
        save()
        Log.info("\(Self.storeName): added custom rule \"\(trimmedBanned)\"")
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
    /// Word-boundary aware so "use" doesn't match inside "user".
    func scan(_ text: String) -> [StyleMatch] {
        let ns = text as NSString
        var out: [StyleMatch] = []
        for rule in enabledRules {
            if let range = Self.wordRange(of: rule.banned, in: ns) {
                out.append(StyleMatch(rule: rule, matchedText: ns.substring(with: range)))
            }
        }
        return out
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
