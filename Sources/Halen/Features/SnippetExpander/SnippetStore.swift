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
        Snippet(trigger: ";summary",  kind: .ai,
                value: "Summarise the following text in three concise bullet points. Output only the bullets, no preamble.",
                displayName: "Summarise prior text", builtin: true),
        Snippet(trigger: ";rephrase", kind: .ai,
                value: "Rewrite the following paragraph more concisely while keeping its meaning. Output only the rewrite, no preamble.",
                displayName: "Rephrase prior paragraph", builtin: true),
        Snippet(trigger: ";formal",   kind: .ai,
                value: "Rewrite the following paragraph in a more formal, professional tone. Output only the rewrite.",
                displayName: "Make prior paragraph formal", builtin: true),
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
        // Replace if trigger exists (and isn't a builtin)
        if let idx = snippets.firstIndex(where: { $0.trigger.lowercased() == normalisedTrigger.lowercased() }) {
            if snippets[idx].builtin { return }
            snippets[idx] = Snippet(
                trigger: normalisedTrigger,
                kind: kind,
                value: value,
                displayName: displayName,
                builtin: false
            )
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

    private func ensureBuiltins() {
        let existing = Set(snippets.map(\.trigger))
        var changed = false
        for s in Self.builtins where !existing.contains(s.trigger) {
            snippets.append(s)
            changed = true
        }
        if changed { save() }
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
