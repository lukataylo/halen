import Foundation
import Observation

/// A single clarity-detection rule. `prompt` is the description fed to the
/// classifier in a multi-label classification task ("which of these issues
/// does the text have?"). Built-in rules can be toggled but not deleted;
/// custom rules both.
struct ClarityRule: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let prompt: String
    var enabled: Bool
    let builtin: Bool
}

/// JSON-backed, `@Observable` store of `ClarityRule`s. Seeded with sensible
/// built-ins on first launch; user-added rules persist alongside them.
/// Modeled directly on `SentimentRulesStore`; load/save/slug plumbing lives
/// in `JSONRuleStoreSupport`.
@Observable
@MainActor
final class ClarityRulesStore {
    private(set) var rules: [ClarityRule] = []

    private let fileURL: URL
    private static let storeName = "ClarityRulesStore"

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let loaded = JSONRuleStoreSupport.load(
            ClarityRule.self, from: fileURL, storeName: Self.storeName) {
            rules = loaded
        }
        ensureDefaults()
    }

    static let builtins: [ClarityRule] = [
        .init(id: "passive_voice", label: "Passive voice",
              prompt: "uses passive voice where active voice would be clearer and more direct",
              enabled: true, builtin: true),
        .init(id: "run_on", label: "Run-on sentences",
              prompt: "has run-on or overly long sentences that should be split for readability",
              enabled: true, builtin: true),
        .init(id: "dangling_modifier", label: "Dangling modifiers",
              prompt: "has a dangling or misplaced modifier that attaches to the wrong subject",
              enabled: true, builtin: true),
        .init(id: "vague_pronoun", label: "Vague pronouns",
              prompt: "uses a vague pronoun (\"this\", \"it\", \"that\") with no clear referent",
              enabled: true, builtin: true),
        .init(id: "hedging", label: "Hedging language",
              prompt: "is weighed down with hedging — \"just\", \"sort of\", \"I think maybe\" — that weakens the point",
              enabled: false, builtin: true),
    ]

    // MARK: - Mutations

    func setEnabled(_ id: String, enabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled = enabled
        save()
    }

    func addCustomRule(label: String, prompt: String) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedPrompt.isEmpty else { return }
        rules.append(ClarityRule(
            id: JSONRuleStoreSupport.slugId(from: trimmedLabel),
            label: trimmedLabel, prompt: trimmedPrompt,
            enabled: true, builtin: false))
        save()
        Log.info("\(Self.storeName): added custom rule \"\(trimmedLabel)\"")
    }

    func remove(_ id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }), !rules[idx].builtin else { return }
        rules.remove(at: idx)
        save()
    }

    var sorted: [ClarityRule] {
        rules.sorted { lhs, rhs in
            if lhs.builtin != rhs.builtin { return lhs.builtin && !rhs.builtin }
            return lhs.label.lowercased() < rhs.label.lowercased()
        }
    }

    var enabledRules: [ClarityRule] { rules.filter(\.enabled) }

    // MARK: - Persistence

    /// Add any built-in rules the user doesn't already have, preserving their
    /// toggles for built-ins they've already seen.
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
