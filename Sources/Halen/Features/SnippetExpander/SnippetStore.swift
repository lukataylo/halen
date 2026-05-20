import Foundation
import Observation

/// JSON-backed @Observable snippet store. Builtins are merged in on every launch
/// so future additions ship without overwriting user customisations.
@Observable
@MainActor
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
        ensureBuiltins()
    }

    static let builtins: [Snippet] = [
        Snippet(trigger: ";sig",      kind: .staticText, value: "— Sent via Halen, my local writing agent",
                displayName: "Signature", builtin: true),
        Snippet(trigger: ";today",    kind: .dynamic,    value: "today",
                displayName: "Today's date", builtin: true),
        Snippet(trigger: ";time",     kind: .dynamic,    value: "time",
                displayName: "Current time", builtin: true),
        // Appends after the trigger — keeps the original text in place.
        Snippet(trigger: ";summary",  kind: .ai,
                value: "Summarise the following text in three concise bullet points. Output only the bullets, no preamble.",
                displayName: "Summarise prior text", builtin: true, replacesPrior: false),
        // Replaces the paragraph the user just wrote with a rewrite.
        Snippet(trigger: ";rephrase", kind: .ai,
                value: "Rewrite the following paragraph more concisely while keeping its meaning. Output only the rewrite, no preamble, no quotes.",
                displayName: "Rephrase prior paragraph", builtin: true, replacesPrior: true),
        Snippet(trigger: ";formal",   kind: .ai,
                value: "Rewrite the following paragraph in a more formal, professional tone. Output only the rewrite, no preamble, no quotes.",
                displayName: "Make prior paragraph formal", builtin: true, replacesPrior: true),
        Snippet(trigger: ";casual",   kind: .ai,
                value: "Rewrite the following paragraph in a friendlier, more casual tone. Output only the rewrite, no preamble, no quotes.",
                displayName: "Make prior paragraph casual", builtin: true, replacesPrior: true),
    ]

    // MARK: - Lookup

    func snippet(for trigger: String) -> Snippet? {
        snippets.first(where: { $0.trigger.lowercased() == trigger.lowercased() })
    }

    // MARK: - Mutations

    func addCustom(trigger: String, kind: Snippet.Kind, value: String, displayName: String) {
        let normalisedTrigger = normalise(trigger)
        guard !normalisedTrigger.isEmpty,
              !displayName.trimmingCharacters(in: .whitespaces).isEmpty,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Replace if a non-builtin trigger exists, else append. Builtins get
        // overridden via `update(_:)` which writes a custom entry that
        // `ensureBuiltins` then suppresses the builtin for.
        if let idx = snippets.firstIndex(where: {
            $0.trigger.lowercased() == normalisedTrigger.lowercased() && !$0.builtin
        }) {
            snippets[idx] = Snippet(
                trigger: normalisedTrigger,
                kind: kind,
                value: value,
                displayName: displayName,
                builtin: false
            )
        } else if snippets.contains(where: {
            $0.trigger.lowercased() == normalisedTrigger.lowercased() && $0.builtin
        }) {
            // Same trigger as a builtin and the user is "adding" — treat as
            // an override. Suppress the builtin and append a custom.
            snippets.removeAll {
                $0.trigger.lowercased() == normalisedTrigger.lowercased() && $0.builtin
            }
            snippets.append(Snippet(
                trigger: normalisedTrigger,
                kind: kind,
                value: value,
                displayName: displayName,
                builtin: false
            ))
        } else {
            snippets.append(Snippet(
                trigger: normalisedTrigger,
                kind: kind,
                value: value,
                displayName: displayName,
                builtin: false
            ))
        }
        save()
        Log.info("SnippetStore: added \(normalisedTrigger) (\(kind.rawValue))")
    }

    /// Edit an existing snippet's value / name / kind. Editing a builtin
    /// converts it to a custom override — the original prompt-engineered
    /// builtin is suppressed at load time as long as the override exists.
    /// Resetting the snippet (via reset) restores the builtin.
    func update(trigger: String, kind: Snippet.Kind, value: String, displayName: String) {
        addCustom(trigger: trigger, kind: kind, value: value, displayName: displayName)
    }

    func remove(_ trigger: String) {
        guard let idx = snippets.firstIndex(where: { $0.trigger == trigger }) else { return }
        guard !snippets[idx].builtin else { return }
        snippets.remove(at: idx)
        save()
    }

    func reset() {
        snippets.removeAll()
        ensureBuiltins()
    }

    /// Sort built-ins first, then by trigger.
    var sorted: [Snippet] {
        snippets.sorted { lhs, rhs in
            if lhs.builtin != rhs.builtin { return lhs.builtin && !rhs.builtin }
            return lhs.trigger.lowercased() < rhs.trigger.lowercased()
        }
    }

    // MARK: - Helpers

    private func normalise(_ trigger: String) -> String {
        var t = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        if !t.hasPrefix(";") { t = ";" + t }
        return t.filter { $0.isLetter || $0.isNumber || $0 == ";" }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var version: Int
        var snippets: [Snippet]
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            snippets = payload.snippets
            Log.info("SnippetStore: loaded \(snippets.count) snippets")
        } catch {
            Log.debug("SnippetStore: no existing file")
        }
    }

    /// Refresh built-in snippets on every launch so prompt tweaks, new
    /// triggers (e.g. ;casual), and the replacesPrior flag propagate without
    /// requiring users to wipe their snippets.json. User-added (builtin=false)
    /// entries are preserved untouched. Builtins are suppressed if a custom
    /// snippet with the same trigger exists (the user "overrode" them via
    /// edit) — that's how editing a builtin sticks across launches.
    private func ensureBuiltins() {
        let custom = snippets.filter { !$0.builtin }
        let overriddenTriggers = Set(custom.map { $0.trigger.lowercased() })
        let activeBuiltins = Self.builtins.filter {
            !overriddenTriggers.contains($0.trigger.lowercased())
        }
        let merged = activeBuiltins + custom
        // Only persist when the merge actually changed something — the common
        // case (no new builtins since last launch, no overrides) is a no-op,
        // and an unconditional `save()` here was a main-thread disk write on
        // every launch. `Snippet` is `Equatable`, so this is an exact compare.
        guard merged != snippets else { return }
        snippets = merged
        save()
    }

    private func save() {
        do {
            let payload = Payload(version: 1, snippets: snippets)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("SnippetStore save failed: \(error.localizedDescription)")
        }
    }
}
