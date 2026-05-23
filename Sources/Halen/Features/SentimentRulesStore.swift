import Foundation
import Observation

/// A single tone-detection rule. The `prompt` is fed to the classifier as the
/// description of this category in a multi-category classification task.
/// Built-in rules can be toggled but not deleted; custom rules can be both.
struct SentimentRule: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let prompt: String
    /// The only mutable field — built-in rules can be turned off, custom
    /// rules can be enabled/disabled in Settings.
    var enabled: Bool
    let builtin: Bool
    let colorName: String

    enum CodingKeys: String, CodingKey {
        case id, label, prompt, enabled, builtin, colorName
    }
}

/// JSON-backed, `@Observable` store of `SentimentRule`s. Seeded with sensible
/// defaults on first launch; user-added rules persist alongside them. The
/// load/save/slug plumbing lives in `JSONRuleStoreSupport`.
@Observable
@MainActor
final class SentimentRulesStore {
    private(set) var rules: [SentimentRule] = []

    private let fileURL: URL
    private static let storeName = "SentimentRulesStore"

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let loaded = JSONRuleStoreSupport.load(
            SentimentRule.self, from: fileURL, storeName: Self.storeName) {
            rules = loaded
        }
        ensureDefaults()
    }

    static let builtins: [SentimentRule] = [
        .init(id: "hostile", label: "Hostile",
              prompt: "the text reads as hostile, aggressive, threatening, or angry at someone",
              enabled: true, builtin: true, colorName: "red"),
        .init(id: "irritated", label: "Irritated",
              prompt: "the text reads as irritated, frustrated, sharp, or short with the reader",
              enabled: true, builtin: true, colorName: "orange"),
        .init(id: "passive_aggressive", label: "Passive-aggressive",
              prompt: "the text reads as passive-aggressive — subtle hostility, sarcasm, backhanded compliments, or pointed politeness",
              enabled: false, builtin: true, colorName: "yellow"),
        .init(id: "anxious", label: "Anxious",
              prompt: "the text reads as anxious, overly apologetic, self-deprecating, or anxious to please",
              enabled: false, builtin: true, colorName: "blue"),
        .init(id: "overly_corporate", label: "Overly corporate",
              prompt: "the text reads as overly corporate, jargon-laden, or hollow business-speak",
              enabled: false, builtin: true, colorName: "gray"),
    ]

    // MARK: - Mutations

    func setEnabled(_ id: String, enabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled = enabled
        save()
    }

    func addCustomRule(label: String, prompt: String, colorName: String = "purple") {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedPrompt.isEmpty else { return }
        rules.append(SentimentRule(
            id: JSONRuleStoreSupport.slugId(from: trimmedLabel),
            label: trimmedLabel, prompt: trimmedPrompt,
            enabled: true, builtin: false, colorName: colorName))
        save()
        Log.info("\(Self.storeName): added custom rule \"\(trimmedLabel)\"")
    }

    func remove(_ id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }), !rules[idx].builtin else { return }
        rules.remove(at: idx)
        save()
    }

    /// Ordered by builtin first, then by label.
    var sorted: [SentimentRule] {
        rules.sorted { lhs, rhs in
            if lhs.builtin != rhs.builtin { return lhs.builtin && !rhs.builtin }
            return lhs.label.lowercased() < rhs.label.lowercased()
        }
    }

    var enabledRules: [SentimentRule] { rules.filter(\.enabled) }

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
