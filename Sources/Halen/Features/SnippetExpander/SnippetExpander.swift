import Foundation
import SwiftUI
import ApplicationServices

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
        let replacesPrior = snippet.replacesPrior == true

        // Compute the range we'll replace and the prior text we'll feed the model.
        // When replacesPrior is true, we replace the entire prior paragraph + the
        // trigger; otherwise we only replace the trigger and the prior text is
        // appended-to (e.g. ;summary).
        let priorEnd = tokenRange.location
        let paragraphStart = replacesPrior
            ? paragraphStartLocation(in: ns, before: priorEnd)
            : max(0, priorEnd - 500)
        let priorText = priorEnd > paragraphStart
            ? ns.substring(with: NSRange(location: paragraphStart, length: priorEnd - paragraphStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // The range we'll mutate.
        let replaceRange: NSRange
        if replacesPrior {
            replaceRange = NSRange(location: paragraphStart, length: NSMaxRange(tokenRange) - paragraphStart)
        } else {
            replaceRange = tokenRange
        }

        guard !priorText.isEmpty || !replacesPrior else {
            // No prior text to rewrite — nothing useful to do. Leave the trigger
            // intact so the user notices.
            return
        }

        // Capture the field we're expanding in *now*. The Gemma response is
        // async and can take several seconds; if the user alt-tabs away in the
        // meantime we must still write back to this element, not whatever is
        // focused when the response lands.
        let targetElement = caretObserver?.currentElement

        // Step 1: show a placeholder so something visibly happens immediately.
        let placeholder = "[…]"
        let placeholderWritten = applyReplacement(placeholder, at: replaceRange, trigger: snippet.trigger, in: targetElement)
        let placeholderRange = NSRange(
            location: replaceRange.location,
            length: (placeholder as NSString).length
        )
        Log.info("SnippetExpander: \(snippet.trigger) placeholder write=\(placeholderWritten) priorTextLen=\(priorText.count) range=\(replaceRange.location),\(replaceRange.length)")

        let prompt = """
        \(snippet.value)

        Paragraph:
        \(priorText)
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 500, temperature: 0.4, taskKind: .generation)

        Task { @MainActor [services, weak self] in
            // Tell the caret overlay we're working so the user sees a busy
            // indicator during the multi-second Gemma call. `defer` guarantees
            // the matching "finished" fires on every exit path below.
            services.eventBus.publish(.inferenceActivity(.init(
                phase: .started, source: "snippet-expander", timestamp: Date())))
            defer {
                services.eventBus.publish(.inferenceActivity(.init(
                    phase: .finished, source: "snippet-expander", timestamp: Date())))
            }
            do {
                let response = try await services.inference.complete(request)
                let cleaned = response.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                guard !cleaned.isEmpty else {
                    Log.warn("SnippetExpander: \(snippet.trigger) returned empty body, restoring trigger")
                    self?.applyReplacement(replacesPrior ? priorText : snippet.trigger,
                                            at: placeholderRange,
                                            trigger: snippet.trigger,
                                            in: targetElement)
                    return
                }
                Log.info("SnippetExpander: \(snippet.trigger) completed (\(response.latencyMs)ms) responseLen=\(cleaned.count)")
                let wrote = self?.applyReplacement(cleaned, at: placeholderRange, trigger: snippet.trigger, in: targetElement) ?? false
                if !wrote {
                    Log.warn("SnippetExpander: \(snippet.trigger) response AX write failed at range \(placeholderRange.location),\(placeholderRange.length) — target element stale or unsupported")
                }
            } catch {
                Log.warn("SnippetExpander: AI snippet \(snippet.trigger) failed: \(error)")
                self?.applyReplacement(replacesPrior ? priorText : snippet.trigger,
                                        at: placeholderRange,
                                        trigger: snippet.trigger,
                                        in: targetElement)
            }
        }
    }

    /// Returns the UTF-16 offset just after the most recent newline before
    /// `location`, or 0 if there isn't one. Treats the prior paragraph as
    /// everything since the last hard break.
    private func paragraphStartLocation(in ns: NSString, before location: Int) -> Int {
        var idx = location
        while idx > 0 {
            let ch = ns.character(at: idx - 1)
            if ch == 10 /* \n */ { return idx }
            idx -= 1
        }
        return 0
    }

    /// When `element` is supplied the write targets that specific field even if
    /// focus has since moved (used for async AI responses). When nil it falls
    /// back to whatever is currently focused (instant static/dynamic snippets).
    @discardableResult
    private func applyReplacement(_ replacement: String, at range: NSRange, trigger: String,
                                  in element: AXUIElement? = nil) -> Bool {
        recentWrites.append(PendingWrite(trigger: trigger, timestamp: Date()))
        if let element {
            return caretObserver?.replaceRange(range, with: replacement, in: element) ?? false
        }
        return caretObserver?.replaceRange(range, with: replacement) ?? false
    }
}
