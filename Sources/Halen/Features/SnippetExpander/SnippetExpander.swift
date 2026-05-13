import Foundation
import SwiftUI

/// Type `;tag` followed by a separator (space / punctuation) and Halen swaps it
/// for the snippet's content. Static snippets are instant; AI snippets show a
/// "[…]" placeholder, call Gemma 4, then replace with the response.
@MainActor
final class SnippetExpander: HalenPlugin {
    let id = "com.halen.snippet-expander"
    let name = "Snippet Expander"
    let summary = "Type ;tag to expand into your snippets or AI-generated content."
    let icon = "text.bubble"
    let category: PluginCategory = .productivity

    let store: SnippetStore
    private let services: HalenServices
    private weak var caretObserver: CaretObserver?
    private var task: Task<Void, Never>?

    /// Self-edit suppression: ignore our own write-backs on the next pause cycle.
    private struct PendingWrite: Equatable {
        let trigger: String
        let timestamp: Date
    }
    private var recentWrites: [PendingWrite] = []

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
        let dir = services.storageDirectory(for: "com.halen.snippet-expander")
        self.store = SnippetStore(fileURL: dir.appending(path: "snippets.json"))
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
                guard let self else { return }
                if case .textPaused(let p) = event {
                    self.handle(text: p.text, caretOffset: p.caretOffset)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        recentWrites.removeAll()
    }

    func makeDetailView() -> AnyView {
        AnyView(SnippetExpanderDetailView(store: store))
    }

    // MARK: - Trigger detection

    private func handle(text: String, caretOffset: Int) {
        let ns = text as NSString
        let length = ns.length
        guard caretOffset > 0, caretOffset <= length else { return }

        // Trigger when the char just before the caret is a separator (the canonical
        // "user finished a word" signal — same as TypoFixer).
        guard let lastChar = character(ns, at: caretOffset - 1),
              lastChar.isWhitespace || lastChar.isPunctuation else { return }

        var end = caretOffset - 1
        while end > 0, let ch = character(ns, at: end - 1),
              ch.isWhitespace || ch.isPunctuation {
            end -= 1
        }
        var start = end
        while start > 0, let ch = character(ns, at: start - 1),
              !ch.isWhitespace, !ch.isPunctuation {
            start -= 1
        }
        // Extend backward to include the snippet sentinel ';' — otherwise the
        // word-boundary scan stops *after* it (semicolons count as punctuation)
        // and we never see the trigger.
        if start > 0, let preceding = character(ns, at: start - 1), preceding == ";" {
            start -= 1
        }
        guard start < end else { return }

        let token = ns.substring(with: NSRange(location: start, length: end - start))
        guard token.hasPrefix(";") else { return }

        // Suppress our own self-edits within 3s
        let now = Date()
        recentWrites.removeAll { now.timeIntervalSince($0.timestamp) > 3 }
        if recentWrites.contains(where: { $0.trigger == token }) { return }

        guard let snippet = store.snippet(for: token) else { return }
        let tokenRange = NSRange(location: start, length: end - start)
        expand(snippet, at: tokenRange, fullText: ns)
    }

    private func character(_ ns: NSString, at index: Int) -> Character? {
        guard index >= 0, index < ns.length else { return nil }
        guard let scalar = Unicode.Scalar(ns.character(at: index)) else { return nil }
        return Character(scalar)
    }

    // MARK: - Expansion

    private func expand(_ snippet: Snippet, at tokenRange: NSRange, fullText ns: NSString) {
        switch snippet.kind {
        case .staticText:
            applyReplacement(snippet.value, at: tokenRange, trigger: snippet.trigger)

        case .dynamic:
            let value = dynamicValue(for: snippet.value)
            applyReplacement(value, at: tokenRange, trigger: snippet.trigger)

        case .ai:
            expandAI(snippet: snippet, at: tokenRange, fullText: ns)
        }
    }

    private func dynamicValue(for key: String) -> String {
        let now = Date()
        let formatter = DateFormatter()
        switch key.lowercased() {
        case "today":
            formatter.dateFormat = "EEEE d MMMM yyyy"
            return formatter.string(from: now)
        case "time":
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: now)
        default:
            return ""
        }
    }

    private func expandAI(snippet: Snippet, at tokenRange: NSRange, fullText ns: NSString) {
        // Step 1: replace the trigger with a placeholder so the user sees something happening.
        let placeholder = "[…]"
        applyReplacement(placeholder, at: tokenRange, trigger: snippet.trigger)
        let placeholderRange = NSRange(location: tokenRange.location, length: (placeholder as NSString).length)

        // Grab the ~500 chars immediately before the trigger as the prior context.
        let priorEnd = tokenRange.location
        let priorStart = max(0, priorEnd - 500)
        let priorText = priorEnd > priorStart
            ? ns.substring(with: NSRange(location: priorStart, length: priorEnd - priorStart))
            : ""

        let prompt = """
        \(snippet.value)

        Text:
        \(priorText)
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 300, temperature: 0.4)

        Task { @MainActor [services, weak self] in
            do {
                let response = try await services.inference.complete(request)
                let cleaned = response.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !cleaned.isEmpty else {
                    self?.applyReplacement(snippet.trigger, at: placeholderRange, trigger: snippet.trigger)
                    return
                }
                Log.info("SnippetExpander: AI snippet \(snippet.trigger) completed (\(response.latencyMs)ms)")
                self?.applyReplacement(cleaned, at: placeholderRange, trigger: snippet.trigger)
            } catch {
                Log.warn("SnippetExpander: AI snippet \(snippet.trigger) failed: \(error)")
                self?.applyReplacement(snippet.trigger, at: placeholderRange, trigger: snippet.trigger)
            }
        }
    }

    private func applyReplacement(_ replacement: String, at range: NSRange, trigger: String) {
        recentWrites.append(PendingWrite(trigger: trigger, timestamp: Date()))
        caretObserver?.replaceRange(range, with: replacement)
    }
}
