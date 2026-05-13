import Foundation
import Observation

/// A single tone-detection rule. The `prompt` is fed to Gemma as the description
/// of this category in a multi-category classification task. Built-in rules can
/// be toggled but not deleted; custom rules can be both.
struct SentimentRule: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var prompt: String
    var enabled: Bool
    var builtin: Bool
    var colorName: String

    enum CodingKeys: String, CodingKey {
        case id, label, prompt, enabled, builtin, colorName
    }
}

/// JSON-backed, @Observable store of `SentimentRule`s. Seeded with sensible
/// defaults on first launch; user-added rules persist alongside them.
@Observable
@MainActor
final class SentimentRulesStore {
    private(set) var rules: [SentimentRule] = []

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
        ensureDefaults()
    }

    static let builtins: [SentimentRule] = [
        .init(
            id: "hostile",
            label: "Hostile",
            prompt: "the text reads as hostile, aggressive, threatening, or angry at someone",
            enabled: true,
            builtin: true,
            colorName: "red"
        ),
        .init(
            id: "irritated",
            label: "Irritated",
            prompt: "the text reads as irritated, frustrated, sharp, or short with the reader",
            enabled: true,
            builtin: true,
            colorName: "orange"
        ),
        .init(
            id: "passive_aggressive",
            label: "Passive-aggressive",
            prompt: "the text reads as passive-aggressive — subtle hostility, sarcasm, backhanded compliments, or pointed politeness",
            enabled: false,
            builtin: true,
            colorName: "yellow"
        ),
        .init(
            id: "anxious",
            label: "Anxious",
            prompt: "the text reads as anxious, overly apologetic, self-deprecating, or anxious to please",
            enabled: false,
            builtin: true,
            colorName: "blue"
        ),
        .init(
            id: "overly_corporate",
            label: "Overly corporate",
            prompt: "the text reads as overly corporate, jargon-laden, or hollow business-speak",
            enabled: false,
            builtin: true,
            colorName: "gray"
        ),
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
        let slug = trimmedLabel
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let id = "\(slug.isEmpty ? "rule" : slug)_\(UUID().uuidString.prefix(6).lowercased())"
        rules.append(SentimentRule(
            id: id,
            label: trimmedLabel,
            prompt: trimmedPrompt,
            enabled: true,
            builtin: false,
            colorName: colorName
        ))
        save()
        Log.info("SentimentRulesStore: added custom rule \"\(trimmedLabel)\"")
    }

    func remove(_ id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        guard !rules[idx].builtin else { return }
        rules.remove(at: idx)
        save()
    }

    /// Convenience: ordered by builtin first, then by label.
    var sorted: [SentimentRule] {
        rules.sorted { lhs, rhs in
            if lhs.builtin != rhs.builtin { return lhs.builtin && !rhs.builtin }
            return lhs.label.lowercased() < rhs.label.lowercased()
        }
    }

    var enabledRules: [SentimentRule] {
        rules.filter { $0.enabled }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var version: Int
        var rules: [SentimentRule]
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            rules = payload.rules
            Log.info("SentimentRulesStore: loaded \(rules.count) rules")
        } catch {
            Log.debug("SentimentRulesStore: no existing file")
        }
    }

    /// Add any builtin rules the user doesn't already have. Doesn't touch existing
    /// entries (preserves user toggles / edits for builtins).
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
        do {
            let payload = Payload(version: 1, rules: rules)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("SentimentRulesStore save failed: \(error.localizedDescription)")
        }
    }
}
