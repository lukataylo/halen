import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import IOKit.hid

/// Type `;tag` followed by a separator (space / punctuation) and Halen swaps it
/// for the snippet's content. Static snippets are instant; AI snippets show a
/// "[…]" placeholder, call Gemma 4, then replace with the response.
///
/// Also owns the ⌃⌥R "rephrase selection" hotkey: with text highlighted in
/// any app, ⌃⌥R rewrites just that selection in place. Separate from the `;`
/// triggers (which always act on the prior paragraph) because typing a
/// trigger would destroy the highlight.
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

    /// NSEvent monitor handles for the ⌃⌥R rephrase-selection hotkey.
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    /// Sentinel passed to `applyReplacement` for hotkey-driven writes — keeps
    /// the self-edit suppression list happy without colliding with any real
    /// `;` trigger (it starts with a NUL, which can't be typed).
    private static let rephraseHotkeyTrigger = "\u{0}rephrase-hotkey"

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
                if case .textPaused(let payload) = event {
                    self.handle(text: payload.text, caretOffset: payload.caretOffset)
                }
            }
        }
        installRephraseHotkey()
    }

    func stop() {
        task?.cancel()
        task = nil
        recentWrites.removeAll()
        if let m = globalHotkeyMonitor { NSEvent.removeMonitor(m); globalHotkeyMonitor = nil }
        if let m = localHotkeyMonitor  { NSEvent.removeMonitor(m); localHotkeyMonitor  = nil }
    }

    // MARK: - Rephrase-selection hotkey (⌃⌥R)

    /// Install global + local `.keyDown` monitors for ⌃⌥R. Same mechanism as
    /// AskHalen's ⌃H — NSEvent monitors rather than Carbon, so the hotkey
    /// fires regardless of which app is focused. Needs Input Monitoring;
    /// `IOHIDRequestAccess` is idempotent if AskHalen already requested it.
    private func installRephraseHotkey() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        // ⌃⌥R: Control+Option held (and nothing else), key "r".
        // `charactersIgnoringModifiers` returns "r" even with Option down,
        // which would otherwise map the key to "®".
        let isHotkey: (NSEvent) -> Bool = { event in
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option]
                && event.charactersIgnoringModifiers?.lowercased() == "r"
        }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isHotkey(event) else { return }
            MainActor.assumeIsolated { self?.rephraseSelection() }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if isHotkey(event) {
                MainActor.assumeIsolated { self?.rephraseSelection() }
                return nil   // consume — don't let ⌃⌥R fall through to Halen's own UI
            }
            return event
        }
        Log.info("SnippetExpander: ⌃⌥R rephrase-selection monitors installed (global=\(globalHotkeyMonitor != nil), local=\(localHotkeyMonitor != nil))")
    }

    /// Rephrase whatever text is currently selected, in place. No-op when
    /// nothing is selected (the hotkey only does something with an active
    /// highlight, by design). Mirrors `expandAI`'s placeholder + async
    /// write-back so it's robust to the user editing during the Gemma call.
    private func rephraseSelection() {
        guard let element = caretObserver?.currentElement else {
            Log.info("SnippetExpander: ⌃⌥R — no focused element")
            return
        }
        guard let cfRange = axReadSelectedRange(element), cfRange.length > 0 else {
            Log.info("SnippetExpander: ⌃⌥R — no active selection, ignoring")
            return
        }
        let selected = axReadSelectedText(element)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.info("SnippetExpander: ⌃⌥R — selection empty/whitespace, ignoring")
            return
        }
        let selRange = NSRange(location: cfRange.location, length: cfRange.length)

        let prompt = """
        Rewrite the following text more clearly and concisely while keeping its meaning and tone. Output only the rewrite, no preamble, no quotes.

        Text:
        \(selected)
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 500,
                                       temperature: 0.4, taskKind: .generation)
        Log.info("SnippetExpander: ⌃⌥R rephrasing \(selected.count)-char selection")
        runPlaceholderInference(
            range: selRange,
            in: element,
            request: request,
            // On an empty / failed response, restore the original selection.
            restoreText: selected,
            label: Self.rephraseHotkeyTrigger,
            source: "snippet-rephrase"
        )
    }

    func makeDetailView() -> AnyView {
        AnyView(SnippetExpanderDetailView(store: store))
    }

    // MARK: - Trigger detection

    private func handle(text: String, caretOffset: Int) {
        let ns = text as NSString
        guard var tokenRange = wordRange(in: ns, endingBefore: caretOffset) else { return }

        // Extend backward to include the snippet sentinel ';' — the word
        // scan stops *after* it (semicolons count as punctuation), so the
        // trigger token itself would otherwise be missing its leading ';'.
        if tokenRange.location > 0,
           let preceding = character(ns, at: tokenRange.location - 1), preceding == ";" {
            tokenRange = NSRange(location: tokenRange.location - 1,
                                 length: tokenRange.length + 1)
        }

        let token = ns.substring(with: tokenRange)
        guard token.hasPrefix(";") else { return }

        // Suppress our own self-edits within 3s
        let now = Date()
        recentWrites.removeAll { now.timeIntervalSince($0.timestamp) > 3 }
        if recentWrites.contains(where: { $0.trigger == token }) { return }

        guard let snippet = store.snippet(for: token) else { return }
        expand(snippet, at: tokenRange, fullText: ns)
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
        let replaceRange: NSRange = replacesPrior
            ? NSRange(location: paragraphStart, length: NSMaxRange(tokenRange) - paragraphStart)
            : tokenRange

        guard !priorText.isEmpty || !replacesPrior else {
            // No prior text to rewrite — nothing useful to do. Leave the trigger
            // intact so the user notices.
            return
        }

        let prompt = """
        \(snippet.value)

        Paragraph:
        \(priorText)
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 500,
                                       temperature: 0.4, taskKind: .generation)
        runPlaceholderInference(
            range: replaceRange,
            in: caretObserver?.currentElement,
            request: request,
            // On an empty / failed response, restore what was there: the prior
            // paragraph for a replacesPrior snippet, else just the trigger.
            restoreText: replacesPrior ? priorText : snippet.trigger,
            label: snippet.trigger,
            source: "snippet-expander"
        )
    }

    /// Shared "AI write" choreography for both `;` AI snippets and the ⌃⌥R
    /// rephrase hotkey. Drops a `[…]` placeholder over `range` for immediate
    /// feedback, anchors the caret overlay's busy indicator to it, runs
    /// `request` against the inference router, then re-locates the placeholder
    /// (the user may have edited the field during the multi-second call) and
    /// replaces it with the cleaned response — or with `restoreText` when the
    /// model returns nothing or the call fails. `label` is used for the
    /// self-edit suppression key and log lines.
    private func runPlaceholderInference(
        range: NSRange,
        in element: AXUIElement?,
        request: InferenceRequest,
        restoreText: String,
        label: String,
        source: String
    ) {
        let placeholder = "[…]"
        let placeholderWritten = applyReplacement(placeholder, at: range, trigger: label, in: element)
        let placeholderRange = NSRange(location: range.location,
                                       length: (placeholder as NSString).length)
        Log.info("SnippetExpander: \(label) placeholder write=\(placeholderWritten) range=\(range.location),\(range.length)")

        // Anchor the overlay's busy state to the placeholder's real on-screen
        // bounds — more reliable than the overlay's racy last-known caret.
        let overlayAnchor: Event.CaretRect? = {
            guard let element,
                  let axRect = axReadBounds(element, range: CFRange(
                      location: placeholderRange.location, length: placeholderRange.length)) else {
                return nil
            }
            let cocoa = axRectToCocoa(axRect)
            return .init(x: cocoa.minX, y: cocoa.minY, width: cocoa.width, height: cocoa.height)
        }()

        Task { @MainActor [services, overlayAnchor, weak self] in
            // Tell the caret overlay we're working so the user sees a busy
            // indicator during the multi-second Gemma call. `defer` guarantees
            // the matching "finished" fires on every exit path below.
            services.eventBus.publish(.inferenceActivity(.init(
                phase: .started, source: source, anchor: overlayAnchor, timestamp: Date())))
            defer {
                services.eventBus.publish(.inferenceActivity(.init(
                    phase: .finished, source: source, timestamp: Date())))
            }

            let start = Date()
            // Tracks what we last wrote into the field and where. Each streamed
            // snapshot is located by searching for the *previously written*
            // text (the user may have edited elsewhere mid-stream, shifting it)
            // and overwritten in place. Seeded with the `[…]` placeholder.
            var lastWritten = placeholder
            var writtenRange = placeholderRange

            /// Re-locate `lastWritten` in the (possibly-edited) field and
            /// overwrite it with `snapshot`. Returns false when the text has
            /// vanished (user deleted it) or the AX write fails — caller stops.
            ///
            /// `@MainActor` annotation is needed because local functions don't
            /// always inherit the enclosing Task's `@MainActor` isolation under
            /// strict concurrency; without it the calls to `locatePlaceholder`
            /// and `applyReplacement` (both main-actor isolated) are flagged.
            @MainActor func flush(_ snapshot: String) -> Bool {
                guard let self,
                      let target = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element)
                else { return false }
                guard self.applyReplacement(snapshot, at: target, trigger: label, in: element) else {
                    return false
                }
                lastWritten = snapshot
                writtenRange = NSRange(location: target.location, length: (snapshot as NSString).length)
                return true
            }

            var latest = ""
            var lastFlush = Date.distantPast
            do {
                for try await snapshot in services.inference.stream(request) {
                    latest = snapshot
                    guard !snapshot.isEmpty else { continue }
                    // Throttle AX writes — a per-token write storm into a
                    // foreign text field is janky. ~11 fps still reads as
                    // live "typing". The first snapshot always passes (the
                    // seed timestamp is `.distantPast`) so generation appears
                    // to start immediately.
                    if Date().timeIntervalSince(lastFlush) < 0.09 { continue }
                    lastFlush = Date()
                    if !flush(snapshot) {
                        Log.warn("SnippetExpander: \(label) streamed text gone from field — stopping")
                        return
                    }
                }
                // Final authoritative write: clean wrapper quotes off the last
                // snapshot and reconcile (intermediate writes were raw).
                let cleaned = latest.unwrappedModelText
                guard let self,
                      let writeRange = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element)
                else {
                    Log.warn("SnippetExpander: \(label) streamed text gone from field — skipping final write")
                    return
                }
                guard !cleaned.isEmpty else {
                    Log.warn("SnippetExpander: \(label) returned empty body — restoring")
                    self.applyReplacement(restoreText, at: writeRange, trigger: label, in: element)
                    return
                }
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                Log.info("SnippetExpander: \(label) completed streamed (\(elapsed)ms) responseLen=\(cleaned.count)")
                if !self.applyReplacement(cleaned, at: writeRange, trigger: label, in: element) {
                    Log.warn("SnippetExpander: \(label) final AX write failed at \(writeRange.location),\(writeRange.length) — target element stale or unsupported")
                }
            } catch {
                Log.warn("SnippetExpander: \(label) failed: \(error)")
                guard let self,
                      let writeRange = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element) else { return }
                self.applyReplacement(restoreText, at: writeRange, trigger: label, in: element)
            }
        }
    }

    /// Re-find `placeholder` in the (possibly-edited) field. Used both for the
    /// initial `[…]` marker and, during streaming, for the previously-written
    /// snapshot — generation is async and multi-second, so if the user typed
    /// elsewhere meanwhile the text will have shifted. Returns its current
    /// range, the original `expected` range if the field can't be read, or nil
    /// if the text is gone (the user deleted it — don't write anything).
    private func locatePlaceholder(_ placeholder: String, expectedAt expected: NSRange,
                                   in element: AXUIElement?) -> NSRange? {
        guard let target = element ?? caretObserver?.currentElement,
              let current = axReadString(target, kAXValueAttribute) else {
            return expected
        }
        let ns = current as NSString
        var searchFrom = 0
        var best: NSRange?
        while searchFrom < ns.length {
            let found = ns.range(of: placeholder, options: [],
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard found.location != NSNotFound else { break }
            if best == nil ||
                abs(found.location - expected.location) < abs(best!.location - expected.location) {
                best = found
            }
            searchFrom = found.location + max(1, found.length)
        }
        return best
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
