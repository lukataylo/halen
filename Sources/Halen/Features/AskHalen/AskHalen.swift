import AppKit
import SwiftUI
import Carbon.HIToolbox
import Observation
import ApplicationServices

/// ⌘H anywhere → a floating palette that asks the local AI a one-shot
/// question, with the user's current context (focused app, selected text,
/// recent clipboard, current paragraph) automatically attached.
///
/// Designed to be **the** "I'd reach for ChatGPT here" surface but local and
/// contextual: the user doesn't have to copy-paste the email/code/draft they
/// want help with — Halen sees what's on their screen already.
///
/// Hotkey note: registering ⌘H globally takes precedence over the per-app
/// "Hide window" binding that macOS apps inherit from `Cmd-H`. Users who
/// rely on that should disable this plugin or rebind via Settings (future).
@MainActor
final class AskHalen: HalenPlugin {
    let id = "com.halen.ask-halen"
    let name = "Ask Halen"
    let summary = "⌘H anywhere to ask your local AI with the page's context attached."
    let icon = "sparkles.rectangle.stack"
    let category: PluginCategory = .productivity

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?

    private let hotkey = HotkeyRegistrar()

    private let state = AskHalenState()
    private var panel: NSPanel?
    private var inflightTask: Task<Void, Never>?

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
    }

    func start() {
        let modifiers = UInt32(cmdKey)
        let key = UInt32(kVK_ANSI_H)
        let ok = hotkey.register(keyCode: key, modifiers: modifiers,
                                 id: HotkeyID.askHalen.rawValue) { [weak self] in
            MainActor.assumeIsolated { self?.togglePalette() }
        }
        if !ok {
            Log.warn("AskHalen: ⌘H registration failed (another app may already own it)")
        }
    }

    func stop() {
        hotkey.unregister()
        inflightTask?.cancel()
        inflightTask = nil
        closePalette()
    }

    func makeDetailView() -> AnyView {
        AnyView(AskHalenDetailView())
    }

    // MARK: - Palette

    private func togglePalette() {
        if panel != nil { closePalette() } else { openPalette() }
    }

    private func openPalette() {
        // Snapshot context BEFORE the palette steals focus. Once our panel
        // becomes key, the focused element changes and AX reads would point
        // at the palette's text field, not the user's source app.
        state.context = AskHalenContext.capture(via: caretObserver)
        state.question = ""
        state.response = ""
        state.errorMessage = nil
        state.isStreaming = false

        let size = NSSize(width: 640, height: 220)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // The non-activating panel doesn't yield the source app's key-window
        // status — text writes via AX still target the field the user was in.

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
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
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

    private func submit() {
        let question = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        inflightTask?.cancel()
        state.isStreaming = true
        state.response = ""
        state.errorMessage = nil

        let prompt = AskHalenContext.buildPrompt(question: question, context: state.context)
        let request = InferenceRequest(prompt: prompt, tier: .medium,
                                       maxTokens: 600, temperature: 0.4,
                                       taskKind: .generation)

        inflightTask = Task { @MainActor [services, weak self] in
            do {
                let response = try await services.inference.complete(request)
                guard let self, !Task.isCancelled else { return }
                self.state.response = response.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.state.isStreaming = false
                Log.info("AskHalen: response (\(response.latencyMs)ms, model=\(response.modelId))")
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
            copyResponse()
            closePalette()
            return
        }
        // Capture before closePalette nukes `state.response` via cancel paths.
        let response = state.response
        closePalette()
        // Tiny delay so the palette has actually relinquished key-window and
        // any deferred focus restoration has settled.
        Task { @MainActor [caretObserver] in
            try? await Task.sleep(for: .milliseconds(80))

            // If the user ⌘Tabbed away after opening the palette, writing to
            // the captured element lands in a window they can no longer see.
            // Copy instead so the response is still recoverable.
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontPID == originalPID else {
                Log.info("AskHalen: focus moved (was pid \(originalPID), now \(frontPID ?? -1)) — copying instead of inserting")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(response, forType: .string)
                return
            }

            // Re-read the AX selection NOW rather than using {0, 0}. In
            // native AppKit apps, passing range {0, 0} to AX would set the
            // caret to position 0 and insert there — i.e., at the top of
            // the user's email, not at their actual caret. Re-reading gets
            // the live position; falling through to {0, 0} only happens in
            // apps where AX can't tell us (Electron, web fields), and the
            // clipboard ⌘V fallback in that path uses the OS-tracked caret
            // anyway.
            let cf = axReadSelectedRange(element) ?? CFRange(location: 0, length: 0)
            let range = NSRange(location: cf.location, length: cf.length)
            caretObserver?.replaceRange(range, with: response, in: element)
        }
    }
}

/// View-side reactive bundle for the palette. `@Observable` so the SwiftUI
/// palette updates as the response streams in (today: arrives whole) and the
/// streaming flag toggles.
@MainActor
@Observable
final class AskHalenState {
    var question: String = ""
    var response: String = ""
    var errorMessage: String?
    var isStreaming: Bool = false
    var context: AskHalenContext = .empty
}

/// Default detail view — Ask Halen has nothing to configure today; the hotkey
/// is the surface. Future settings (custom hotkey, default model tier) land here.
private struct AskHalenDetailView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.halenCobalt)
            Text("Press ⌘H anywhere")
                .font(.system(.callout, weight: .medium))
            Text("A floating palette opens with your focused app, selected text, and recent clipboard already in context. Ask anything — Halen answers locally using whichever backend is active. Note: this overrides macOS's per-app ⌘H (Hide window) shortcut.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }
}
