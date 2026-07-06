import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import HalenPluginAPI

/// Type `;tag` followed by a separator (space / punctuation) and Halen swaps it
/// for the snippet's content. Static snippets are instant; AI snippets show a
/// "[…]" placeholder, call Gemma 4, then replace with the response.
///
/// Also owns the ⌃⌥R "rephrase selection" hotkey: with text highlighted in
/// any app, ⌃⌥R rewrites just that selection in place. Separate from the `;`
/// triggers (which always act on the prior paragraph) because typing a
/// trigger would destroy the highlight.
@MainActor
public final class SnippetExpander: HalenPlugin {
    public static let pluginManifest = PluginManifest(
        id: "com.halen.snippet-expander", name: "Snippet Expander",
        summary: "Type ;tag to expand text, dates, and AI rewrites anywhere.",
        version: "0.4.0",
        events: ["text.pause", "caret.moved", "app.focused"],
        capabilities: [.observeText, .observeKeystrokes, .insertText, .hotkeys,
                       .notifications, .snippets, .toneProfiles, .clipboard],
        icon: "text.bubble", category: .productivity)

    public var manifest: PluginManifest { Self.pluginManifest }

    private let context: PluginContext
    /// Host-owned snippet library, granted via the `.snippets` capability.
    /// nil means the grant was revoked — expansion no-ops (logged in start()).
    private var store: SnippetStore? { context.snippets }
    private var task: Task<Void, Never>?

    /// Self-edit suppression: ignore our own write-backs on the next pause cycle.
    private struct PendingWrite: Equatable {
        let trigger: String
        let timestamp: Date
    }
    private var recentWrites: [PendingWrite] = []

    /// Reconstructs typed text from the global keystroke stream so snippets
    /// expand even in text boxes the Accessibility API can't read — Chromium
    /// web fields, Electron apps — with no browser extension required.
    private let keystrokeBuffer = KeystrokeBuffer()

    /// In-flight email reply draft Task. Cancelled by a subsequent
    /// invocation so a second ⌃⌥E supersedes a slow first one. The Email
    /// Reply standalone plugin folded into Snippet Expander — it's surfaced
    /// as the `;reply` built-in trigger plus the ⌃⌥E hotkey for users who
    /// prefer chords.
    private var emailReplyInflight: Task<Void, Never>?
    /// Built-in trigger that fires the email-reply drafter instead of
    /// expanding a snippet. Special-cased in `handle(text:caretOffset:)`
    /// so it bypasses the normal expansion path. Single source of truth lives
    /// in `SnippetStore` so the settings UI agrees with this detection path.
    private static let emailReplyTrigger = SnippetStore.emailReplyTrigger

    /// Sentinel passed to `applyReplacement` for hotkey-driven writes — keeps
    /// the self-edit suppression list happy without colliding with any real
    /// `;` trigger (it starts with a NUL, which can't be typed).
    private static let rephraseHotkeyTrigger = "\u{0}rephrase-hotkey"

    public init(context: PluginContext) {
        self.context = context
    }

    public func start() {
        guard task == nil else { return }
        if context.snippets == nil {
            Log.warn("SnippetExpander: snippets capability not granted — expansion disabled")
        }
        task = Task { @MainActor [context, weak self] in
            for await event in context.events.subscribe() {
                guard let self else { return }
                switch event {
                case .textPaused(let payload):
                    self.handle(text: payload.text, caretOffset: payload.caretOffset)
                case .appFocused:
                    // The caret is now in a different app — any half-typed
                    // trigger in the keystroke buffer is no longer valid.
                    self.keystrokeBuffer.noteAppSwitch()
                default:
                    break
                }
            }
        }
        registerHotkeys()

        // The keystroke buffer is the path that makes snippets work in text
        // boxes the Accessibility API can't see (Chromium web fields, Electron
        // apps): no `text.pause` event ever arrives for those, so trigger
        // detection is reconstructed from the global keystroke stream instead.
        // The host owns the Input Monitoring TCC prompt — fire-and-forget the
        // request here so first use triggers it.
        Task { [context] in
            _ = await context.permissions.request(.inputMonitoring)
        }
        keystrokeBuffer.onTrigger = { [weak self] token, delimiter, preceding in
            self?.handleKeystrokeTrigger(token: token, delimiter: delimiter, preceding: preceding)
        }
        keystrokeBuffer.start()
    }

    public func stop() {
        task?.cancel()
        task = nil
        recentWrites.removeAll()
        keystrokeBuffer.stop()
        context.hotkeys?.unregisterAll()
        emailReplyInflight?.cancel()
        emailReplyInflight = nil
    }

    // MARK: - Hotkeys (⌃⌥R rephrase, ⌃⌥E email reply)

    /// Register both chords through the host's hotkey service — the host owns
    /// monitor installation, Input Monitoring prompts, and conflict
    /// registration; the plugin just names the chords and reacts.
    private func registerHotkeys() {
        guard let hotkeys = context.hotkeys else {
            Log.warn("SnippetExpander: hotkeys capability not granted — ⌃⌥R/⌃⌥E disabled")
            return
        }
        let rephraseOK = hotkeys.register(
            id: "rephrase", keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option]
        ) { [weak self] in
            self?.rephraseSelection()
        }
        let emailOK = hotkeys.register(
            id: "email-reply", keyCode: UInt32(kVK_ANSI_E), modifiers: [.control, .option]
        ) { [weak self] in
            self?.fireEmailReply()
        }
        Log.info("SnippetExpander: hotkeys registered (⌃⌥R=\(rephraseOK), ⌃⌥E=\(emailOK))")
    }

    /// Cancel any prior draft, kick off a new one. Wraps the static
    /// `EmailReplyDrafter.draft` so the inflight slot stays in the
    /// plugin instance (the drafter itself is stateless).
    private func fireEmailReply() {
        emailReplyInflight?.cancel()
        emailReplyInflight = EmailReplyDrafter.draft(context: context)
    }

    /// Rephrase whatever text is currently selected, in place. No-op when
    /// nothing is selected (the hotkey only does something with an active
    /// highlight, by design). Mirrors `expandAI`'s placeholder + async
    /// write-back so it's robust to the user editing during the Gemma call.
    private func rephraseSelection() {
        guard let element = context.text?.focusedElement else {
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
        let request = InferenceRequest(prompt: prompt, tier: .medium,
                                       maxTokens: rewriteMaxTokens(forInputChars: selected.count),
                                       temperature: 0.4, taskKind: .generation)
        Log.info("SnippetExpander: ⌃⌥R rephrasing \(selected.count)-char selection")
        runPlaceholderInference(
            range: selRange,
            in: element,
            request: request,
            // On an empty / failed response, restore the original selection.
            restoreText: selected,
            label: Self.rephraseHotkeyTrigger,
            source: "snippet-rephrase",
            // The selection is the user's own text — recover to the clipboard
            // if the in-place restore can't land.
            restoreIsUserText: true
        )
    }

    public func makeDetailView() -> AnyView {
        guard let store = context.snippets else {
            return AnyView(EmptyPluginDetailView(plugin: self))
        }
        return AnyView(SnippetExpanderDetailView(store: store))
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

        // Built-in email-reply action — bypasses the SnippetStore path
        // entirely. The trigger is consumed (replaced by an empty
        // string) so the user doesn't see ";reply" lingering in their
        // text while the draft is composing.
        if token.lowercased() == Self.emailReplyTrigger {
            applyReplacement("", at: tokenRange,
                             trigger: Self.emailReplyTrigger,
                             announce: "Drafting email reply")
            fireEmailReply()
            return
        }

        guard let snippet = store?.snippet(for: token) else { return }
        expand(snippet, at: tokenRange, fullText: ns)
    }

    // MARK: - Expansion

    private func expand(_ snippet: Snippet, at tokenRange: NSRange, fullText ns: NSString) {
        switch snippet.kind {
        case .staticText:
            // VoiceOver users hear nothing from a silent AX write — surface
            // the expansion through the announcement bridge. Static/dynamic
            // snippets are one-shot writes; safe to announce the result.
            applyReplacement(snippet.value, at: tokenRange, trigger: snippet.trigger,
                             announce: "Expanded \(snippet.trigger)")

        case .dynamic:
            let value = dynamicValue(for: snippet.value)
            applyReplacement(value, at: tokenRange, trigger: snippet.trigger,
                             announce: "Expanded \(snippet.trigger)")

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

    /// Output budget for a rewrite. A whole-message rewrite (;casual on a
    /// multi-paragraph field, or a long ⌃⌥R selection) needs more than the old
    /// fixed 500 or the tail gets truncated. ~4 chars/token, so `/2` gives ~2×
    /// the input's token count — ample headroom even when formalizing expands
    /// the text. Capped at 4000 so a runaway can't spin forever; the AX path
    /// bounds its input to `maxRewriteChars` so the budget can always cover it.
    private func rewriteMaxTokens(forInputChars inputChars: Int) -> Int {
        min(4000, max(500, inputChars / 2))
    }

    /// Upper bound on how much prior text a whole-field rewrite feeds the model.
    /// Comfortably covers a long email; beyond it we rewrite only the most
    /// recent slice (and replace only that slice) so the model's `maxTokens`
    /// budget can always reproduce the whole input — no silent tail truncation,
    /// no head deletion. ;casual on a giant document is not the use case.
    private static let maxRewriteChars = 6000

    private func expandAI(snippet: Snippet, at tokenRange: NSRange, fullText ns: NSString) {
        let replacesPrior = snippet.replacesPrior == true

        // Compute the range we'll replace and the prior text we'll feed the model.
        // When replacesPrior is true, we replace the entire field up to the
        // trigger (a tone rewrite acts on the whole message, not just the last
        // paragraph); otherwise we only replace the trigger and the prior text
        // is appended-to (e.g. ;summary).
        let priorEnd = tokenRange.location
        let paragraphStart = replacesPrior
            ? max(0, priorEnd - Self.maxRewriteChars)
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

        Text:
        \(priorText)
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium,
                                       maxTokens: replacesPrior ? rewriteMaxTokens(forInputChars: priorText.count) : 500,
                                       temperature: 0.4, taskKind: .generation)
        runPlaceholderInference(
            range: replaceRange,
            in: context.text?.focusedElement,
            request: request,
            // On an empty / failed response, restore what was there: the prior
            // text for a replacesPrior snippet, else just the trigger.
            restoreText: replacesPrior ? priorText : snippet.trigger,
            label: snippet.trigger,
            source: "snippet-expander",
            // replacesPrior replaced the user's own text — recover to the
            // clipboard if the in-place restore can't land.
            restoreIsUserText: replacesPrior
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
    ///
    /// `restoreIsUserText` is true when `restoreText` is the user's own content
    /// (a whole-field tone rewrite, or a ⌃⌥R selection) rather than just a
    /// trigger string. In that case, if the in-place restore can't land — the
    /// placeholder is gone because the user edited the field — we fall back to
    /// the clipboard so their text is never lost rather than silently dropped.
    private func runPlaceholderInference(
        range: NSRange,
        in element: AXUIElement?,
        request: InferenceRequest,
        restoreText: String,
        label: String,
        source: String,
        restoreIsUserText: Bool = false
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

        Task { @MainActor [context, overlayAnchor, weak self] in
            // Tell the caret overlay we're working so the user sees a busy
            // indicator during the multi-second Gemma call. `defer` guarantees
            // the matching "finished" fires on every exit path below.
            context.events.publish(.inferenceActivity(.init(
                phase: .started, source: source, anchor: overlayAnchor, timestamp: Date())))
            defer {
                context.events.publish(.inferenceActivity(.init(
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
                for try await snapshot in context.inference.stream(request) {
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
                    if restoreIsUserText {
                        self?.copyWithToast(restoreText, reason: "Halen lost its place in the field")
                    }
                    return
                }
                guard !cleaned.isEmpty else {
                    Log.warn("SnippetExpander: \(label) returned empty body — restoring")
                    self.applyReplacement(restoreText, at: writeRange, trigger: label, in: element)
                    return
                }
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                Log.info("SnippetExpander: \(label) completed streamed (\(elapsed)ms) responseLen=\(cleaned.count)")
                // VoiceOver bridge: announce the final result of the AI
                // expansion. Intermediate token writes pass `announce: nil`
                // (would otherwise spam VO with every snapshot); only this
                // authoritative replacement speaks. The rephrase hotkey gets
                // a distinct phrasing from a `;` snippet.
                let announcement = label == Self.rephraseHotkeyTrigger
                    ? "Rephrased selection"
                    : "Expanded \(label)"
                if !self.applyReplacement(cleaned, at: writeRange, trigger: label,
                                          in: element, announce: announcement) {
                    Log.warn("SnippetExpander: \(label) final AX write failed at \(writeRange.location),\(writeRange.length) — target element stale or unsupported")
                }
            } catch {
                Log.warn("SnippetExpander: \(label) failed: \(error)")
                guard let self,
                      let writeRange = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element)
                else {
                    if restoreIsUserText {
                        self?.copyWithToast(restoreText, reason: "Halen lost its place in the field")
                    }
                    return
                }
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
        guard let target = element ?? context.text?.focusedElement,
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

    /// When `element` is supplied the write targets that specific field even if
    /// focus has since moved (used for async AI responses). When nil it falls
    /// back to whatever is currently focused (instant static/dynamic snippets).
    ///
    /// `announce` is the VoiceOver string posted after a successful write.
    /// Default nil means "don't announce" — intermediate streaming writes
    /// pass nil so VoiceOver doesn't speak every token; only the final
    /// cleaned write (or the static/dynamic one-shot) announces.
    @discardableResult
    private func applyReplacement(_ replacement: String, at range: NSRange, trigger: String,
                                  in element: AXUIElement? = nil,
                                  announce: String? = nil) -> Bool {
        recentWrites.append(PendingWrite(trigger: trigger, timestamp: Date()))
        if let element {
            return context.text?.replaceRange(range, with: replacement, in: element,
                                              describedAs: announce) ?? false
        }
        return context.text?.replaceRange(range, with: replacement,
                                          describedAs: announce) ?? false
    }

    // MARK: - Keystroke-buffer expansion (works without Accessibility)

    /// A `;trigger` was reconstructed from the global keystroke stream — the
    /// path that covers browser web fields, Electron apps, and anything else
    /// the AX tree can't read. `delimiter` is the separator the user typed to
    /// close the trigger; `preceding` is the text typed before it this session.
    private func handleKeystrokeTrigger(token: String, delimiter: String, preceding: String) {
        // Defense-in-depth for passwords: if the Accessibility tree IS readable
        // and reports a secure text field, never expand or read context here —
        // even if process-wide secure input (IsSecureEventInputEnabled, checked
        // in KeystrokeBuffer) didn't engage. A web password field the AX tree
        // can't see at all is undetectable from the keystroke stream; the buffer
        // mitigates that case by never logging it and resetting on navigation.
        if let element = context.text?.focusedElement,
           axReadString(element, kAXSubroleAttribute as String) == (kAXSecureTextFieldSubrole as String) {
            keystrokeBuffer.reset()
            return
        }

        // Built-in `;reply` drafts a reply to the *focused email*, which only
        // exists in a mail client the Accessibility tree can read. It is not a
        // store snippet (its store entry is a doc-string placeholder), so the
        // keystroke path must NOT paste that value. Leave the trigger in place
        // and don't claim it — the AX `text.pause` path owns `;reply` and will
        // fire `fireEmailReply()` for it.
        if token.lowercased() == Self.emailReplyTrigger { return }

        // Self-edit guard — shared with the AX `text.pause` path so the two
        // detectors never both act on the same trigger.
        let now = Date()
        recentWrites.removeAll { now.timeIntervalSince($0.timestamp) > 3 }
        if recentWrites.contains(where: { $0.trigger == token }) { return }

        guard let snippet = store?.snippet(for: token) else { return }

        switch snippet.kind {
        case .staticText:
            writeFromKeystroke(snippet.value, token: token, delimiter: delimiter)
        case .dynamic:
            writeFromKeystroke(dynamicValue(for: snippet.value), token: token, delimiter: delimiter)
        case .ai:
            expandAIFromKeystroke(snippet: snippet, token: token,
                                  delimiter: delimiter, preceding: preceding)
        }
    }

    /// Universal write for static / dynamic snippets detected via the
    /// keystroke buffer. Backspaces the typed `;trigger` plus its closing
    /// separator and pastes the snippet value (re-appending the separator the
    /// user typed). Goes through the clipboard fallback, so it lands in *any*
    /// text box regardless of AX support.
    private func writeFromKeystroke(_ value: String, token: String, delimiter: String) {
        recentWrites.append(PendingWrite(trigger: token, timestamp: Date()))
        keystrokeBuffer.reset()

        // Count in grapheme clusters, not UTF-16 units: each synthesized
        // backspace deletes one user-perceived character, so an emoji/flag in
        // the trigger would over-delete and eat a character to its left if we
        // counted NSString.length here.
        let deleteCount = token.count + delimiter.count
        let replacement = value + delimiter
        // Suppress the buffer's view of our own synthesized keystrokes, then
        // give the focused app a beat to commit the separator that triggered
        // us before we backspace over it.
        keystrokeBuffer.suppress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.context.text?.pasteFallback(text: replacement, deleteCount: deleteCount) ?? false
            }
        }
        Log.info("SnippetExpander: keystroke-expanded \(token) (delete=\(deleteCount))")
    }

    /// AI snippet detected via the keystroke buffer. The write always goes
    /// through the keystroke/paste path: AX *writes* are unreliable in browser
    /// web fields — they highlight the trigger but the replacement never lands
    /// — so we do *not* defer to the AX `text.pause` path the way an earlier
    /// version did (that bug left `;summary` highlighting the word and then
    /// doing nothing in Dia). Prior context comes from what the user typed
    /// this session, falling back to an AX *read* — which is reliable — of the
    /// field. The result is written blind, but only if the user stayed still
    /// during the model call; otherwise it lands on the clipboard with a
    /// notification, so a multi-second response is never dropped in the wrong
    /// place. The one case still handed to the AX path: a `replacesPrior`
    /// snippet whose paragraph predates this typing session, since that can't
    /// be deleted by counting keystrokes.
    private func expandAIFromKeystroke(snippet: Snippet, token: String,
                                       delimiter: String, preceding: String) {
        let replacesPrior = snippet.replacesPrior == true
        let typed = preceding.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prior context: what the user typed this session, or — when that's
        // empty (they clicked into text that was already there) — an AX read
        // of the field up to the trigger.
        var priorText = typed
        if priorText.isEmpty,
           let element = context.text?.focusedElement,
           let axText = axReadString(element, kAXValueAttribute),
           let r = axText.range(of: token, options: .backwards) {
            priorText = String(axText[..<r.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A replacesPrior tone rewrite (;rephrase, ;formal, ;casual) acts on the
        // WHOLE field, not just the line typed since the last newline — the
        // keystroke buffer resets on Return, so `typed` is only the current line.
        // Read the full field: if it holds more than this session's typed line,
        // the keystroke path can't backspace across the earlier newlines, so hand
        // off to the AX `text.pause` path, which selects and replaces the whole
        // field. If the field can't be read, fall through and rewrite what we do
        // have (the current line) rather than nothing.
        if replacesPrior {
            if let element = context.text?.focusedElement,
               let axText = axReadString(element, kAXValueAttribute),
               let r = axText.range(of: token, options: .backwards) {
                let fieldPrior = String(axText[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if fieldPrior.count > typed.count {
                    Log.info("SnippetExpander: \(token) — rewriting whole field, deferring to text.pause path")
                    return
                }
            } else if typed.isEmpty {
                Log.info("SnippetExpander: \(token) — no context to work from, leaving trigger")
                return
            }
        }

        // Bound the prompt — a long email shouldn't be sent whole.
        if priorText.count > 4000 {
            priorText = String(priorText.suffix(4000))
        }
        guard !priorText.isEmpty else {
            Log.info("SnippetExpander: \(token) — no context to work from, leaving trigger")
            return
        }

        // Claim the trigger so the AX path skips it if it also detects it.
        recentWrites.append(PendingWrite(trigger: token, timestamp: Date()))
        keystrokeBuffer.reset()

        let placeholder = "[…]"
        // Grapheme-cluster counts, not UTF-16 units — each backspace deletes
        // one user-perceived character (see writeFromKeystroke). `preceding`
        // can hold emoji, so counting NSString.length here would over-delete
        // past the start of the typed paragraph.
        let tokenLen = token.count + delimiter.count
        // replacesPrior snippets (;rephrase, ;formal, ;casual) swallow the
        // typed paragraph too; ;summary keeps it and appends after.
        let deleteCount = replacesPrior
            ? preceding.count + tokenLen
            : tokenLen
        let pasteText = replacesPrior ? placeholder : placeholder + delimiter
        let placeholderLen = placeholder.count

        keystrokeBuffer.suppress(forMillis: 300)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.context.text?.pasteFallback(text: pasteText, deleteCount: deleteCount) ?? false
            }
        }

        let prompt = """
        \(snippet.value)

        Text:
        \(priorText)
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium,
                                       maxTokens: replacesPrior ? rewriteMaxTokens(forInputChars: priorText.count) : 500,
                                       temperature: 0.4, taskKind: .generation)
        Log.info("SnippetExpander: \(token) — keystroke AI expand (replacesPrior=\(replacesPrior), priorChars=\(priorText.count))")

        Task { @MainActor [context, weak self] in
            // Let the placeholder write settle before baselining activity so
            // our own synthesized keystrokes aren't counted as the user typing.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            let activityBaseline = self.keystrokeBuffer.activityCount

            // Restore the user's original text if the rewrite fails or returns
            // empty. For a replacesPrior snippet we already deleted their whole
            // line and pasted `[…]`, so doing nothing would lose it. (;summary
            // left the text intact, so there's nothing to restore there.)
            @MainActor func restoreOriginal() {
                guard replacesPrior else { return }
                if self.keystrokeBuffer.activityCount == activityBaseline {
                    self.recentWrites.append(PendingWrite(trigger: token, timestamp: Date()))
                    self.keystrokeBuffer.suppress(forMillis: 300)
                    _ = context.text?.pasteFallback(text: priorText, deleteCount: placeholderLen) ?? false
                } else {
                    // User moved on — a blind write would land wrong; hand the
                    // original back via the clipboard so it's never lost.
                    self.copyWithToast(priorText, reason: "Halen couldn't rewrite it")
                }
            }

            context.events.publish(.inferenceActivity(.init(
                phase: .started, source: "snippet-expander", timestamp: Date())))
            defer {
                context.events.publish(.inferenceActivity(.init(
                    phase: .finished, source: "snippet-expander", timestamp: Date())))
            }
            do {
                let response = try await context.inference.complete(request)
                let cleaned = response.text.unwrappedModelText
                guard !cleaned.isEmpty else {
                    Log.warn("SnippetExpander: \(token) keystroke AI returned empty — restoring original")
                    restoreOriginal()
                    return
                }
                if self.keystrokeBuffer.activityCount == activityBaseline {
                    // The user sat still — the placeholder is still right
                    // before the caret, so backspace it and paste the result.
                    self.recentWrites.append(PendingWrite(trigger: token, timestamp: Date()))
                    self.keystrokeBuffer.suppress(forMillis: 300)
                    _ = context.text?.pasteFallback(text: cleaned, deleteCount: placeholderLen) ?? false
                    Log.info("SnippetExpander: \(token) keystroke AI wrote \(cleaned.count) chars")
                } else {
                    // The user typed or clicked during the call — a blind
                    // write would land in the wrong place. Hand off via the
                    // clipboard so the response isn't lost.
                    self.copyWithToast(
                        cleaned,
                        reason: "you kept working while Halen was thinking")
                    Log.info("SnippetExpander: \(token) keystroke AI — field changed, copied to clipboard")
                }
            } catch {
                Log.warn("SnippetExpander: \(token) keystroke AI failed: \(error) — restoring original")
                restoreOriginal()
            }
        }
    }

    /// Put `text` on the clipboard and post a toast — the graceful fallback
    /// when a blind AI write can't be placed. Without the toast the user
    /// would just see the response vanish.
    private func copyWithToast(_ text: String, reason: String) {
        context.clipboard?.write(text)
        context.ui?.toast(
            title: "Snippet result copied",
            body: "Halen couldn't insert it (\(reason)). Press ⌘V to paste — you may need to delete the […] placeholder.")
    }
}
