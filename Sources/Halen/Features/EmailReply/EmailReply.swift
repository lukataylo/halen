import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import UserNotifications

/// ⌃⌥E in a mail app drafts a reply to the message you're reading. Reads the
/// selected / quoted message via Accessibility (reusing `AskHalenContext`),
/// asks the local model for a reply, and either inserts it at the caret (when
/// the caret sits in an editable field) or copies it to the clipboard.
@MainActor
final class EmailReply: HalenPlugin {
    let id = "com.halen.email-reply"
    let name = "Email Reply"
    let summary = "⌃⌥E drafts a reply to the email you're reading."
    let icon = "arrowshape.turn.up.left"
    let category: PluginCategory = .productivity

    /// User-selectable tone for the draft. "Match" defers to the
    /// Tone Profiles plugin's per-app profile (the historical behaviour);
    /// the others override it for this specific reply.
    enum ReplyTone: String, CaseIterable, Sendable {
        case match       // honour the Tone Profiles per-app setting
        case formal
        case casual
        case concise
        case warm

        /// Sentence appended to the reply prompt. `match` returns an empty
        /// string because the caller will already have inserted the tone-
        /// profile clause; the others fully override it.
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

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?
    private let hotkey = HotkeyRegistrar()
    private var inflight: Task<Void, Never>?

    /// Native mail apps the hotkey is scoped to. Browser-based mail (Gmail,
    /// Outlook web) isn't reliably distinguishable from any other tab, so it's
    /// deliberately excluded — the user works around it by selecting the
    /// message text first, which still flows through `AskHalenContext`.
    static let mailBundleIds: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "it.bloop.airmail2",
        "com.canarymail.mac",
        "com.mimestream.Mimestream",
    ]

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
    }

    func start() {
        // ⌃⌥E — Control+Option held, key "E".
        let ok = hotkey.register(
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: UInt32(controlKey | optionKey),
            id: HotkeyID.emailReply.rawValue,
            owner: name,
            onFire: { [weak self] in self?.draftReply() }
        )
        // Failure path is recorded in the conflict registry; Settings
        // shows the offending pair so the user can resolve it.
        Log.info("EmailReply: ⌃⌥E hotkey registered=\(ok)")
    }

    func stop() {
        hotkey.unregister()
        inflight?.cancel()
        inflight = nil
    }

    func makeDetailView() -> AnyView {
        AnyView(EmailReplyDetailView())
    }

    /// Menu-equivalent entry point. Mirrors the ⌃⌥E hotkey path so users
    /// who can't press chord combinations still reach the draft-reply flow
    /// from the dropdown. Same guard rails as the hotkey path: if no mail
    /// app is focused, the user gets the same "focus a mail app" toast.
    func invokeFromMenu() {
        draftReply()
    }

    // MARK: - Drafting

    private func draftReply() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier ?? ""
        guard Self.mailBundleIds.contains(bundleId) else {
            notify(body: "Focus a mail app (Mail, Outlook, Spark, Airmail…) and press ⌃⌥E.")
            return
        }

        // Reuse the palette's context capture — selected text first, then the
        // paragraph around the caret, then the clipboard.
        let context = AskHalenContext.capture(via: caretObserver)
        let original = [context.selectedText, context.currentParagraph, context.clipboardText]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let original else {
            notify(body: "Select the message you want to reply to, then press ⌃⌥E.")
            return
        }
        // Bias the reply's register by the mail app's tone profile — the same
        // host service Sentiment Guard and Clarity Checker read.
        // Tone resolution: a user-selected default ("formal" / "casual" /
        // "concise" / "warm") wins outright. Otherwise fall back to the
        // per-app tone profile (which is the historical default).
        let replyTone = Self.defaultTone
        let toneClause: String
        if replyTone == .match {
            toneClause = services.toneProfiles.profile(for: bundleId).promptClause
        } else {
            toneClause = replyTone.promptClause
        }

        inflight?.cancel()
        inflight = Task { @MainActor [services, weak self] in
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
            do {
                let response = try await services.inference.complete(request)
                guard let self, !Task.isCancelled else { return }
                let draft = response.text.unwrappedModelText
                guard !draft.isEmpty else {
                    self.notify(body: "The model returned an empty draft. Try again.")
                    return
                }
                self.deliver(draft: draft, focusedElement: context.focusedElement)
                Log.info("EmailReply: drafted reply (\(response.latencyMs)ms, \(draft.count) chars)")
            } catch is CancellationError {
                // Superseded by another ⌃⌥E — silent.
            } catch {
                self?.notify(body: "Couldn't draft a reply: \(error.localizedDescription)")
                Log.warn("EmailReply: inference failed: \(error)")
            }
        }
    }

    /// Insert the draft at the caret when the user has a plain caret in an
    /// editable field (they've clicked into the reply box); otherwise — or if
    /// the AX write fails — copy to the clipboard. A non-empty selection means
    /// the original message is highlighted; inserting there would clobber it,
    /// so that path always uses the clipboard.
    private func deliver(draft: String, focusedElement: AXUIElement?) {
        if let element = focusedElement,
           let range = axReadSelectedRange(element), range.length == 0,
           caretObserver?.replaceRange(NSRange(location: range.location, length: 0),
                                       with: draft, in: element) == true {
            Log.info("EmailReply: inserted draft at caret")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft, forType: .string)
        notify(body: "Reply draft copied — press ⌘V in your reply.")
    }

    /// Post a transient system notification. Authorisation is requested
    /// lazily; if denied the `add` fails silently.
    private func notify(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Email Reply"
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }
}
