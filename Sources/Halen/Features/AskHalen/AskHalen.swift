import AppKit
import SwiftUI
import Carbon.HIToolbox
import Observation
import ApplicationServices
import IOKit.hid
import UserNotifications

/// ⌃H anywhere → a floating palette that asks the local AI a one-shot
/// question, with the user's current context (focused app, selected text,
/// recent clipboard, current paragraph) automatically attached.
///
/// Designed to be **the** "I'd reach for ChatGPT here" surface but local and
/// contextual: the user doesn't have to copy-paste the email/code/draft they
/// want help with — Halen sees what's on their screen already.
///
/// Hotkey mechanism: NSEvent global+local monitors, NOT Carbon's
/// RegisterEventHotKey. Carbon accepts the ⌃-letter combo but the OS
/// routes it through NSResponder text-input first, where most fields
/// consume ⌃H as the Unix-backspace control character — so the Carbon
/// handler is never reached. NSEvent monitors observe the keystroke
/// passively, regardless of who has focus. Trade-off: the focused app's
/// text field may also receive a stray backspace when ⌃H fires; for the
/// "open a palette" use case we accept it.
@MainActor
final class AskHalen: HalenPlugin {
    let id = "com.halen.ask-halen"
    let name = "Ask Halen"
    let summary = "⌃H anywhere to ask your local AI with the page's context attached."
    let icon = "sparkles.rectangle.stack"
    let category: PluginCategory = .productivity

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?

    /// NSEvent monitor handles — opaque tokens we must keep alive and pass to
    /// `NSEvent.removeMonitor(_:)` on teardown.
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let state = AskHalenState()
    private var panel: NSPanel?
    private var inflightTask: Task<Void, Never>?

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
    }

    func start() {
        // `NSEvent.addGlobalMonitorForEvents` for `.keyDown` requires the user
        // to grant Input Monitoring — separate from Accessibility. Without it
        // the monitor "installs" (returns a non-nil token) but its callback
        // never fires for events from other apps, so the hotkey looks dead.
        // Request explicitly; macOS shows a one-shot system prompt the first
        // time, returns the cached answer afterwards.
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if !granted {
            Log.warn("AskHalen: Input Monitoring not granted — ⌃H from other apps will not fire. Grant in System Settings → Privacy & Security → Input Monitoring → Halen.")
        }

        // One handler, shared between the global (other apps focused) and
        // local (Halen focused) monitors. `.deviceIndependentFlagsMask`
        // strips caps lock and device-private bits so the equality check
        // matches a clean ⌃H even when caps lock happens to be on.
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                  event.charactersIgnoringModifiers?.lowercased() == "h"
            else { return }
            Log.debug("AskHalen: ⌃H detected — toggling palette")
            MainActor.assumeIsolated { self?.togglePalette() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // No unconditional logging here — this closure fires for EVERY
            // keystroke the user types in EVERY app, and putting their text
            // into Halen's log would be a privacy regression. The handler
            // already logs at debug level when ⌃H specifically is detected.
            handler(event)
        }
        if globalMonitor == nil {
            Log.warn("AskHalen: addGlobalMonitorForEvents returned nil — Input Monitoring blocked")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only consume the event when it's our hotkey — every other
            // keystroke must pass through untouched or we'd hijack Halen's
            // own text fields. Returning `nil` consumes.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
               event.charactersIgnoringModifiers?.lowercased() == "h" {
                handler(event)
                return nil
            }
            return event
        }
        Log.info("AskHalen: ⌃H monitors installed (global=\(globalMonitor != nil), local=\(localMonitor != nil), inputMonitoring=\(granted))")
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        inflightTask?.cancel()
        inflightTask = nil
        closePalette()
        Log.info("AskHalen: ⌃H monitors removed (plugin disabled)")
    }

    func makeDetailView() -> AnyView {
        AnyView(AskHalenDetailView())
    }

    /// Menu-equivalent entry point. Mirrors the ⌃H hotkey path so users who
    /// can't press chord combinations (Switch Control, RSI, non-US layouts
    /// where ⌃H collides) still reach the palette from the dropdown.
    func invokeFromMenu() {
        togglePalette()
    }

    // MARK: - Palette

    private func togglePalette() {
        let wasOpen = panel != nil
        Log.info("AskHalen.toggle: \(wasOpen ? "open→close" : "nil→open")")
        if wasOpen { closePalette() } else { openPalette() }
    }

    private func openPalette() {
        // Snapshot context BEFORE the palette steals focus. The captured
        // `AXUIElement` survives focus changes (AX is per-pid, not per
        // first-responder), so Insert can still write back even when the
        // source app loses key-window status while the palette is up.
        state.context = AskHalenContext.capture(via: caretObserver)
        state.question = ""
        state.response = ""
        state.errorMessage = nil
        state.isStreaming = false
        state.hasSubmitted = false

        let size = NSSize(width: 640, height: 220)
        // `FocusablePanel` (subclass below) forces `canBecomeKey = true`
        // even for borderless windows — without it, NSPanel + .borderless
        // returns NO from canBecomeKey and the SwiftUI `TextField`'s
        // `@FocusState` never fires, leaving the palette uneditable and
        // un-dismissable. `.nonactivatingPanel` is gone for the same
        // reason: it doesn't reliably yield key status to SwiftUI's input
        // pipeline in macOS 14+.
        let p = FocusablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let view = AskHalenPalette(
            state: state,
            onSubmit: { [weak self] in self?.submit() },
            onCopy: { [weak self] in self?.copyResponse() },
            onInsert: { [weak self] in self?.insertAtCaret() },
            onClose: { [weak self] in self?.closePalette() }
        )
        p.contentView = NSHostingView(rootView: view)

        // Centered on the user's current screen, slightly above middle so the
        // palette doesn't sit on top of the caret/text the user was working on.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let origin = NSPoint(
                x: f.midX - size.width / 2,
                y: f.midY + (f.height * 0.10) - size.height / 2
            )
            p.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        // Activate Halen and grab key-window status for the palette so the
        // SwiftUI TextField's @FocusState fires.
        //
        // The deprecated `activate(ignoringOtherApps: true)` is used
        // deliberately: Halen is an accessory app (LSUIElement), and the
        // modern `NSApp.activate()` is a soft request that macOS denies for
        // background-→-foreground transitions from accessory apps invoked
        // via NSEvent monitor callbacks. The deprecated path forces the
        // transfer the way Raycast / Alfred / every other launcher does.
        // SE-0399 marks this deprecated but provides no replacement that
        // works for our case; the warning is suppressed below.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
        Log.info("AskHalen.open: panel shown frame=\(p.frame) isKey=\(p.isKeyWindow) isVisible=\(p.isVisible) screen=\(NSScreen.main?.frame ?? .zero)")
    }

    private func closePalette() {
        // Cancel any in-flight inference — otherwise the response lands in
        // `state.response` after the palette is gone, and the next open()
        // would briefly flash that stale text before resetting.
        inflightTask?.cancel()
        inflightTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Inference

    /// Soft cap on a pasted-in question. The local context window is ~8K
    /// tokens; a single 50K-char paste blows that out before even adding
    /// the captured-context preamble. Trim with a visible note rather than
    /// silently sending a request the backend will refuse.
    private static let maxQuestionChars = 8_000

    /// User-tunable settings — model tier, temperature, what to include in
    /// the captured context. Read fresh on each `submit()`; the detail view
    /// edits the same `UserDefaults` keys via `@AppStorage`.
    private struct UserSettings {
        let tier: ModelTier
        let temperature: Double
        let includeClipboard: Bool
        let includeParagraph: Bool

        static var current: UserSettings {
            let defaults = UserDefaults.standard
            let tierRaw = defaults.string(forKey: tierKey) ?? ModelTier.medium.rawValue
            let tier = ModelTier(rawValue: tierRaw) ?? .medium
            // `object(forKey:) as? Double` is nil when unset → fall back to
            // 0.4 (the long-standing default). A raw `double(forKey:)` would
            // return 0.0 and silently make every reply deterministic, which
            // is not the desired default.
            let temp = (defaults.object(forKey: temperatureKey) as? Double) ?? 0.4
            // Both context toggles default to true — the whole point of
            // Ask Halen is that it sees what you're working on.
            let clip  = (defaults.object(forKey: clipboardKey) as? Bool) ?? true
            let para  = (defaults.object(forKey: paragraphKey) as? Bool) ?? true
            return UserSettings(tier: tier, temperature: temp,
                                includeClipboard: clip, includeParagraph: para)
        }
    }

    // `nonisolated` because these are constant identifier strings, not
    // actor state — the `@MainActor` class wrap inherits down to nested
    // statics by default, which made `UserSettings.current` (called from
    // a nonisolated nested context) trip Swift 6's actor checker on every
    // read. The keys are pure values; nothing to isolate.
    nonisolated static let tierKey        = "halen.askhalen.tier"
    nonisolated static let temperatureKey = "halen.askhalen.temperature"
    nonisolated static let clipboardKey   = "halen.askhalen.includeClipboard"
    nonisolated static let paragraphKey   = "halen.askhalen.includeParagraph"

    private func submit() {
        var question = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if question.count > Self.maxQuestionChars {
            Log.warn("AskHalen: question \(question.count) chars > cap \(Self.maxQuestionChars) — truncating")
            // Trim from the end. The user's intent ("rewrite this email…")
            // usually leads the text; the runaway paste tends to be a long
            // tail.
            question = String(question.prefix(Self.maxQuestionChars))
            state.errorMessage = "Question trimmed to \(Self.maxQuestionChars) characters."
        }
        inflightTask?.cancel()
        state.hasSubmitted = true
        state.isStreaming = true
        state.response = ""
        state.errorMessage = nil

        // VoiceOver bridge — sighted users see the "Thinking…" pane and
        // spinner appear; VO users would otherwise sit in silence while
        // the local model takes 1–4 s. `.medium` waits for the user's
        // current utterance to finish so we don't interrupt them mid-word.
        AnnounceCenter.say("Thinking")

        // Snapshot user settings at submit time — changing the tier or
        // privacy toggles mid-stream shouldn't retroactively alter a
        // request already in flight.
        let settings = UserSettings.current
        // Optionally strip the parts of `context` the user disabled in
        // settings. Clipboard contents are the obvious privacy concern;
        // the paragraph toggle is for users who want the palette to act
        // as a pure question/answer surface untainted by what's on screen.
        var effectiveContext = state.context
        if !settings.includeClipboard {
            effectiveContext = effectiveContext.removingClipboard()
        }
        if !settings.includeParagraph {
            effectiveContext = effectiveContext.removingParagraph()
        }
        let prompt = AskHalenContext.buildPrompt(question: question, context: effectiveContext)
        let request = InferenceRequest(prompt: prompt, tier: settings.tier,
                                       maxTokens: 600, temperature: settings.temperature,
                                       taskKind: .generation)

        inflightTask = Task { @MainActor [services, weak self] in
            do {
                let response = try await services.inference.complete(request)
                guard let self, !Task.isCancelled else { return }
                let trimmed = response.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.state.response = trimmed
                self.state.isStreaming = false
                // The response is whatever the model wrote in reply to the
                // user's prompt — both directions are treated as PII. Log
                // size + a non-reversible fingerprint; the model id and
                // latency stay in the clear for diagnostics.
                Log.info("AskHalen: response (\(response.latencyMs)ms, model=\(response.modelId), chars=\(trimmed.count), text=\(Log.redact(trimmed)))")
            } catch is CancellationError {
                // User pressed Esc or fired another query — silent.
            } catch {
                guard let self else { return }
                self.state.errorMessage = error.localizedDescription
                self.state.isStreaming = false
                Log.warn("AskHalen: inference failed: \(error)")
            }
        }
    }

    private func copyResponse() {
        guard !state.response.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.response, forType: .string)
    }

    /// Insert at whatever element was focused when the palette opened. Closes
    /// the palette so the user's previous focus regains the keyboard. If there
    /// is no captured element OR the user has switched apps since opening the
    /// palette, falls back to a clipboard copy so the response isn't lost.
    private func insertAtCaret() {
        guard !state.response.isEmpty else {
            closePalette()
            return
        }
        guard let element = state.context.focusedElement,
              let originalPID = state.context.appPID else {
            copyResponseWithToast(reason: "no text field was focused when the palette opened")
            closePalette()
            return
        }
        // Capture before closePalette nukes `state.response` via cancel paths.
        let response = state.response
        closePalette()

        // Explicitly re-activate the source app. Without this, dismissing a
        // panel does NOT synchronously hand frontmost-status back to whoever
        // had it before — Halen lingers as the active app, the front-pid
        // check below would fail, and Insert would silently fall back to
        // clipboard. The user perceives "nothing happened" because:
        //   (a) the clipboard write is invisible, and
        //   (b) the caret is in their original app, not Halen.
        // Activating with empty options uses the default behaviour, which
        // for foreground apps brings them back to front.
        if let app = NSRunningApplication(processIdentifier: originalPID) {
            app.activate(options: [])
        }

        Task { @MainActor [weak self, caretObserver] in
            // 150ms — longer than the previous 80ms because the activate()
            // round-trip to WindowServer needs more headroom than just
            // panel-orderOut did. Empirically 80ms was insufficient in
            // Chrome; 150ms is reliable without being user-perceptible.
            try? await Task.sleep(for: .milliseconds(150))

            // If the user ⌘Tabbed away after opening the palette OR the
            // re-activation didn't take, write to the captured element would
            // land in a window the user can't see. Copy and tell them.
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontPID == originalPID else {
                Log.info("AskHalen: focus moved (was pid \(originalPID), now \(frontPID ?? -1)) — falling back to clipboard")
                self?.copyResponseToClipboard(response)
                self?.notifyClipboardFallback(reason: "couldn't return to the original app")
                return
            }

            // Re-read the AX selection NOW rather than using {0, 0}. In
            // native AppKit apps, {0, 0} would insert at the TOP of the
            // text, not at the user's actual caret. Falling through to
            // {0, 0} only happens in apps where AX can't tell us (Electron,
            // web fields), where the clipboard ⌘V fallback uses the
            // OS-tracked caret anyway.
            let cf = axReadSelectedRange(element) ?? CFRange(location: 0, length: 0)
            let range = NSRange(location: cf.location, length: cf.length)
            // describedAs:nil — we post our own higher-priority announcement
            // right below; letting replaceRange announce too would speak the
            // change twice.
            let wrote = caretObserver?.replaceRange(range, with: response,
                                                    in: element,
                                                    describedAs: nil) ?? false
            Log.info("AskHalen: inserted \(response.count) chars at caret")
            // VoiceOver bridge — the answer just landed in the user's
            // original field, possibly seconds after they triggered ⌃H.
            // `.high` priority so it cuts through any VO speech the user
            // started listening to during the wait.
            if wrote {
                AnnounceCenter.say("Answer inserted at cursor", priority: .high)
            }
        }
    }

    /// Copy the response and post a system notification so the user knows
    /// where the text actually went. Used when the AX insert path can't
    /// take (no element captured, focus moved, etc.) — otherwise the user
    /// just sees the palette vanish and assumes Insert was a no-op.
    private func copyResponseWithToast(reason: String) {
        copyResponseToClipboard(state.response)
        notifyClipboardFallback(reason: reason)
    }

    private func copyResponseToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Post a transient system notification so the user knows the response
    /// is on their clipboard. Requests notification authorisation lazily; if
    /// the user has denied it the `add()` call fails silently and the user
    /// still has the text on their clipboard.
    private func notifyClipboardFallback(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Copied to clipboard"
        content.body  = "Halen couldn't insert directly (\(reason)). Press ⌘V to paste."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }
}

/// NSPanel subclass that forces `canBecomeKey` (the default returns `false`
/// for borderless panels, which kills SwiftUI's `@FocusState` and key-press
/// handlers inside the hosted view tree). `canBecomeMain` stays `false` so
/// the panel doesn't claim the App's "main window" status — only key.
final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// View-side reactive bundle for the palette.
///
/// **Why `ObservableObject` not `@Observable`:** the modern `@Observable` +
/// `@Bindable` chain silently failed to re-render the response text inside
/// an `NSHostingView`-backed panel — the model returned a perfect 39-char
/// answer (confirmed in logs: `chars=39, preview="filetype:pdf …"`) but the
/// `Text(state.response)` view stayed blank. `ObservableObject` + `@Published`
/// + `@ObservedObject` is the older API but it's rock-solid in NSHostingView.
@MainActor
final class AskHalenState: ObservableObject {
    @Published var question: String = ""
    @Published var response: String = ""
    @Published var errorMessage: String?
    @Published var isStreaming: Bool = false
    @Published var context: AskHalenContext = .empty
    /// Set true once the user has pressed Enter at least once this session.
    /// Lets the palette tell "haven't asked yet" apart from "asked, got an
    /// empty response" without making either case look like a UI bug.
    @Published var hasSubmitted: Bool = false
}

/// Ask Halen's per-plugin detail view. The hotkey is the surface; the
/// detail panel surfaces the knobs that affect how the palette answers:
/// which model tier to use, how creative the response is allowed to be,
/// and which pieces of on-screen context get sent to the model.
@MainActor
private struct AskHalenDetailView: View {
    @AppStorage(AskHalen.tierKey) private var tierRaw: String = ModelTier.medium.rawValue
    // SwiftUI's `@AppStorage` stores `Double` values, falling back to 0.0
    // when unset — which is why `UserSettings.current` reads via
    // `object(forKey:) as? Double` instead. Here the binding controls the
    // Slider so the absent → 0.4 default needs to be primed in `.onAppear`.
    @AppStorage(AskHalen.temperatureKey) private var temperature: Double = 0.4
    @AppStorage(AskHalen.clipboardKey) private var includeClipboard: Bool = true
    @AppStorage(AskHalen.paragraphKey) private var includeParagraph: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                modelCard
                contextCard
                privacyNote
            }
            .padding(14)
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.halenCobalt)
            Text("Press ⌃H anywhere")
                .font(.system(.callout, weight: .medium))
            Text("A floating palette opens with your focused app, selection, and clipboard in context. Terminals consume ⌃H as backspace, so the hotkey won't fire inside Terminal or iTerm.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .padding(.top, 8)
    }

    private var modelCard: some View {
        card {
            cardHeader("Model")
            Picker("", selection: $tierRaw) {
                Text("Small").tag(ModelTier.small.rawValue)
                Text("Medium").tag(ModelTier.medium.rawValue)
                Text("Large").tag(ModelTier.large.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Small is fastest, Large is highest quality. Medium is the balanced default.")

            HStack(alignment: .firstTextBaseline) {
                Text("Temperature")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", temperature))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Slider(value: $temperature, in: 0.0...1.0, step: 0.05)
            Text("Lower is more literal. Higher is more creative. 0.40 reads as a balanced default for question answering.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextCard: some View {
        card {
            cardHeader("Context")
            Toggle(isOn: $includeParagraph) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Include surrounding paragraph")
                        .font(.system(size: 12))
                    Text("The paragraph your cursor is in. Off makes Ask Halen a pure Q&A surface.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider().opacity(0.3)

            Toggle(isOn: $includeClipboard) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Include clipboard contents")
                        .font(.system(size: 12))
                    Text("Recent clipboard text. Useful for \"summarise what I just copied,\" off if your clipboard has sensitive things you don't want a model to see.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text("Whatever you turn on here is sent to the local model only. Nothing leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Reusable card shell

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    private func cardHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}
