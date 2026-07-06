import AppKit
import ApplicationServices
import HalenPluginAPI

/// Drafts a reply to the email message at the user's cursor. Previously
/// the entire surface area of the standalone `EmailReply` plugin; folded
/// here as a helper that Snippet Expander invokes — once from the
/// `;reply` trigger, once from a global ⌃⌥E hotkey.
///
/// Behaviour preserved verbatim from the standalone plugin:
///   - Bails with a "focus a mail app" toast if the front app isn't on the
///     known list of native mail clients.
///   - Captures the message via `CapturedFieldContext` (selected text →
///     surrounding paragraph → clipboard).
///   - Tone resolution: a user-selected default ("formal" / "casual" /
///     "concise" / "warm") wins; otherwise the per-app Tone Profile.
///   - Delivers inline when the caret is in an editable field with no
///     selection; otherwise drops on the clipboard and notifies.
@MainActor
enum EmailReplyDrafter {
    /// User-selectable tone for the draft. "Match" defers to the per-app
    /// Tone Profile (the historical default); the others override it.
    enum ReplyTone: String, CaseIterable, Sendable {
        case match
        case formal
        case casual
        case concise
        case warm

        /// Sentence appended to the reply prompt. `match` returns an
        /// empty string because the caller injects the tone-profile
        /// clause instead.
        var promptClause: String {
            switch self {
            case .match:   return ""
            case .formal:  return "Write the reply in a formal, professional register."
            case .casual:  return "Write the reply in a casual, relaxed register — friendly and brief."
            case .concise: return "Keep the reply as short as politely possible. Two or three sentences."
            case .warm:    return "Write the reply with a warm, friendly tone — acknowledge the sender before responding."
            }
        }

        var label: String {
            switch self {
            case .match:   return "Match app"
            case .formal:  return "Formal"
            case .casual:  return "Casual"
            case .concise: return "Concise"
            case .warm:    return "Warm"
            }
        }
    }

    static let defaultToneKey = "halen.email-reply.defaultTone"
    static var defaultTone: ReplyTone {
        let raw = UserDefaults.standard.string(forKey: defaultToneKey) ?? ""
        return ReplyTone(rawValue: raw) ?? .match
    }

    /// Native mail apps the action is scoped to. Browser-based mail
    /// (Gmail / Outlook web) isn't reliably distinguishable from any
    /// other tab, so it's deliberately excluded — users work around by
    /// selecting the message text first, which still flows through
    /// `CapturedFieldContext`.
    static let mailBundleIds: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "it.bloop.airmail2",
        "com.canarymail.mac",
        "com.mimestream.Mimestream",
    ]

    /// Tracks the in-flight drafting Task so the caller can cancel it
    /// (e.g. a second ⌃⌥E supersedes the first). Caller-owned because
    /// the drafter itself is stateless.
    typealias DraftTask = Task<Void, Never>

    /// Kick off the draft. Returns the Task so the caller can cancel a
    /// previous one. The Task self-supersedes via `inflight?.cancel()`
    /// in the caller's slot — keeping the drafter stateless means
    /// multiple call sites (`;reply` and ⌃⌥E) share the same race-free
    /// contract.
    @discardableResult
    static func draft(context: PluginContext) -> DraftTask? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier ?? ""
        guard mailBundleIds.contains(bundleId) else {
            notify(context, body: "Focus a mail app (Mail, Outlook, Spark, Airmail…) and try again.")
            return nil
        }

        // Reuse the captured-field snapshot — selected text first, then the
        // paragraph around the caret, then the clipboard.
        let captured = CapturedFieldContext.capture(text: context.text,
                                                    clipboard: context.clipboard)
        let original = [captured.selectedText, captured.currentParagraph, captured.clipboardText]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let original else {
            notify(context, body: "Select the message you want to reply to, then try again.")
            return nil
        }

        // Tone resolution: user-selected default wins; otherwise the per-app
        // Tone Profile. When the tone-profiles grant is missing the clause is
        // empty — a neutral register.
        let replyTone = defaultTone
        let toneClause: String
        if replyTone == .match {
            toneClause = context.toneProfiles?.profile(for: bundleId).promptClause ?? ""
        } else {
            toneClause = replyTone.promptClause
        }

        let prompt = """
        You are drafting a reply to an email on the user's behalf. Write a clear, \
        polite, appropriately concise reply to the message below. \(toneClause) \
        Output ONLY the reply body — no subject line, no preamble, no quotes.

        Message:
        \"\"\"
        \(original)
        \"\"\"
        """
        let request = InferenceRequest(prompt: prompt, tier: .medium,
                                       maxTokens: 600, temperature: 0.5,
                                       taskKind: .generation)

        return Task { @MainActor in
            do {
                let response = try await context.inference.complete(request)
                guard !Task.isCancelled else { return }
                let draftText = response.text.unwrappedModelText
                guard !draftText.isEmpty else {
                    notify(context, body: "The model returned an empty draft. Try again.")
                    return
                }
                deliver(draft: draftText,
                        focusedElement: captured.focusedElement,
                        context: context)
                Log.info("EmailReplyDrafter: drafted reply (\(response.latencyMs)ms, \(draftText.count) chars)")
            } catch is CancellationError {
                // Superseded — silent.
            } catch {
                notify(context, body: "Couldn't draft a reply: \(error.localizedDescription)")
                Log.warn("EmailReplyDrafter: inference failed: \(error)")
            }
        }
    }

    /// Insert the draft at the caret when the user has a plain caret in
    /// an editable field (they've clicked into the reply box); otherwise
    /// — or if the AX write fails — copy to the clipboard. A non-empty
    /// selection means the original message is highlighted; inserting
    /// there would clobber it, so that path always uses the clipboard.
    private static func deliver(draft: String,
                                focusedElement: AXUIElement?,
                                context: PluginContext) {
        if let element = focusedElement,
           let range = axReadSelectedRange(element), range.length == 0,
           context.text?.replaceRange(NSRange(location: range.location, length: 0),
                                      with: draft, in: element, describedAs: nil) == true {
            Log.info("EmailReplyDrafter: inserted draft at caret")
            return
        }
        context.clipboard?.write(draft)
        notify(context, body: "Reply draft copied — press ⌘V in your reply.")
    }

    /// Post a transient toast through the host. No-ops when the
    /// notifications grant is missing.
    private static func notify(_ context: PluginContext, body: String) {
        context.ui?.toast(title: "Email Reply", body: body)
    }
}
