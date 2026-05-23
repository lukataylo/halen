import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices

/// Inline autocomplete: when the user pauses at the end of what they're
/// typing, Halen asks the local model for a short continuation and draws it as
/// gray ghost text in a non-interactive overlay anchored just past the caret.
/// Tab accepts (inserted via Accessibility); any other keystroke dismisses.
///
/// This is an *overlay approximation* — macOS gives no way to draw real
/// inline ghost text inside an arbitrary app's text field, so the gray text
/// floats in a borderless panel positioned at the caret. Alignment is good in
/// native fields and rougher in Electron / web fields. Prototype against
/// TextEdit / Notes.
@MainActor
final class Autocomplete: HalenPlugin {
    let id = "com.halen.autocomplete"
    let name = "Inline Autocomplete"
    let summary = "Suggests the next few words as ghost text — Tab to accept."
    let icon = "text.append"
    let category: PluginCategory = .writing

    /// Extra debounce on top of text.pause before a suggestion request
    /// fires. text.pause already settles upstream; this knob lets users
    /// who find ghost text too eager push the firing point further out.
    /// 0…500 ms range; 0 keeps the historical behaviour.
    static let extraSettleKey = "halen.autocomplete.extraSettleMs"
    static var extraSettleMs: Int {
        let raw = UserDefaults.standard.object(forKey: extraSettleKey) as? Int
        guard let raw, (0...500).contains(raw) else { return 0 }
        return raw
    }

    /// Optional whitelist of app bundle ids. When the set is non-empty,
    /// Autocomplete only suggests in those apps. Defaults to empty (the
    /// historical behaviour: suggest everywhere). Stored as a comma-
    /// separated string for parity with SentimentGuard's ignore list.
    static let whitelistKey = "halen.autocomplete.appWhitelist"
    static var appWhitelist: Set<String> {
        let raw = UserDefaults.standard.string(forKey: whitelistKey) ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?
    /// Tab is registered ONLY while a suggestion is on screen, then immediately
    /// unregistered — a permanently-bound global Tab would hijack tabbing in
    /// every app.
    private let acceptHotkey = HotkeyRegistrar()

    private var eventTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var ghostPanel: NSPanel?
    /// Auto-dismiss timer — frees the captured Tab key if the user pauses on a
    /// suggestion and walks away without accepting or typing.
    private var dismissTimer: Task<Void, Never>?

    /// The suggestion currently shown, and where to insert it on accept.
    private var pendingSuggestion: String?
    private var pendingElement: AXUIElement?
    private var pendingCaretOffset = 0
    /// Bumped on every new request and every dismiss; an in-flight model call
    /// only shows its result while its generation is still current.
    private var generation = 0

    /// Don't bother suggesting until there's enough context to continue.
    private let minContextLength = 20

    /// Plugin sources that currently have an active finding (Sentiment /
    /// Clarity / Style flagged something). While non-empty, Autocomplete
    /// stays silent — overlaying ghost text on top of the tinted Halen
    /// indicator was a real visual collision the user flagged (UX-3), and
    /// suggesting more text into a paragraph that just read as irritated
    /// makes no semantic sense either.
    private var activeFindingSources: Set<String> = []

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
    }

    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .textPaused(let p):
                    // App whitelist — when configured (non-empty), only
                    // suggest in the listed apps. Empty = old behaviour
                    // (suggest everywhere).
                    let whitelist = Self.appWhitelist
                    if !whitelist.isEmpty, !whitelist.contains(p.appBundleId) {
                        self.dismiss()
                        continue
                    }
                    // Extra settle delay — text.pause already settled
                    // upstream, this pushes the suggestion fire a bit
                    // further out for users who find ghost text too eager.
                    let extra = Self.extraSettleMs
                    if extra > 0 {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(extra))
                            guard let self, !Task.isCancelled else { return }
                            self.maybeSuggest(text: p.text, caretOffset: p.caretOffset)
                        }
                    } else {
                        self.maybeSuggest(text: p.text, caretOffset: p.caretOffset)
                    }
                case .caretMoved, .appFocused:
                    // Any movement / focus change makes the ghost stale.
                    self.dismiss()
                case .findingDetected(let p):
                    // Another writing plugin flagged this paragraph — drop
                    // the ghost so the indicator tint owns the surface, and
                    // stay quiet until the finding clears.
                    self.activeFindingSources.insert(p.source)
                    self.dismiss()
                case .findingsCleared(let p):
                    self.activeFindingSources.remove(p.source)
                default:
                    break
                }
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        dismiss()
    }

    func makeDetailView() -> AnyView {
        AnyView(AutocompleteDetailView())
    }

    // MARK: - Suggestion

    private func maybeSuggest(text: String, caretOffset: Int) {
        dismiss()   // clear any previous ghost first

        // Stand down whenever another writing plugin has something to say
        // about the current paragraph — the tinted indicator + popover own
        // that surface, and continuing the irritated/passive sentence with
        // a model suggestion isn't useful.
        guard activeFindingSources.isEmpty else { return }

        let ns = text as NSString
        // Only at end-of-text — mid-paragraph ghosting would overlap real text.
        guard caretOffset >= ns.length, ns.length >= minContextLength else { return }
        // The tail should read mid-thought (last non-space char is a letter or
        // a comma) so we don't suggest after a finished sentence.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, last.isLetter || last == "," else { return }

        guard let element = caretObserver?.currentElement,
              let axCaret = axReadCaretBounds(element) else { return }
        let caretRect = axRectToCocoa(axCaret)
        let needsLeadingSpace = !(text.last?.isWhitespace ?? true)

        generation += 1
        let gen = generation
        let context = String(text.suffix(400))

        suggestTask?.cancel()
        suggestTask = Task { @MainActor [services, weak self] in
            let prompt = """
            Here is the start of something the user is typing. Suggest the next 3 to 8 \
            words that would naturally continue it — just the continuation, no preamble, \
            no quotes, and do not repeat what is already written.

            Text: \(context)
            """
            let request = InferenceRequest(prompt: prompt, tier: .small,
                                           maxTokens: 12, temperature: 0.3,
                                           taskKind: .generation)
            do {
                let response = try await services.inference.complete(request)
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                var suggestion = Self.cleanSuggestion(response.text)
                guard !suggestion.isEmpty else { return }
                if needsLeadingSpace { suggestion = " " + suggestion }
                self.showGhost(suggestion, at: caretRect,
                               element: element, caretOffset: caretOffset)
            } catch {
                // Suggestions are best-effort — a failure is silent.
            }
        }
    }

    /// Trim the model's reply to a single short line of a few words.
    private static func cleanSuggestion(_ raw: String) -> String {
        var s = raw.unwrappedModelText
        if let newline = s.firstIndex(of: "\n") { s = String(s[..<newline]) }
        let words = s.split(separator: " ")
        if words.count > 9 { s = words.prefix(9).joined(separator: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Ghost overlay

    private func showGhost(_ suggestion: String, at caretRect: CGRect,
                           element: AXUIElement, caretOffset: Int) {
        pendingSuggestion = suggestion
        pendingElement = element
        pendingCaretOffset = caretOffset

        let width = min(420, max(40, CGFloat(suggestion.count) * 7.5))
        let height = max(16, caretRect.height)
        let panel = HalenFloatingPanel.make(
            size: NSSize(width: width, height: height),
            level: .statusBar, interactive: false, shadow: false)
        let view = Text(suggestion)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: width, height: height, alignment: .leading)
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrameOrigin(NSPoint(x: caretRect.maxX + 1, y: caretRect.minY))
        // `orderFrontRegardless` — the ghost overlays whatever app the user is
        // in, so it must show even though Halen isn't the active app.
        panel.orderFrontRegardless()
        ghostPanel = panel

        // Tab accepts — registered only for the lifetime of this ghost so
        // normal Tab behaviour is untouched the rest of the time.
        _ = acceptHotkey.register(
            keyCode: UInt32(kVK_Tab), modifiers: 0,
            id: HotkeyID.autocomplete.rawValue,
            onFire: { [weak self] in self?.accept() })

        // Don't hold the Tab key captured indefinitely if the user wanders off.
        dismissTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func accept() {
        guard let suggestion = pendingSuggestion,
              let element = pendingElement else {
            dismiss()
            return
        }
        // Any keystroke would have dismissed the ghost, so the caret hasn't
        // moved since the suggestion was made — `pendingCaretOffset` is valid.
        let range = NSRange(location: pendingCaretOffset, length: 0)
        let wrote = caretObserver?.replaceRange(range, with: suggestion, in: element) ?? false
        Log.info("Autocomplete: accepted suggestion (\(suggestion.count) chars) wrote=\(wrote)")
        dismiss()
    }

    private func dismiss() {
        generation += 1   // invalidate any in-flight suggestion
        suggestTask?.cancel()
        suggestTask = nil
        dismissTimer?.cancel()
        dismissTimer = nil
        ghostPanel?.orderOut(nil)
        ghostPanel = nil
        pendingSuggestion = nil
        pendingElement = nil
        acceptHotkey.unregister()
    }
}
