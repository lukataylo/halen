import AppKit
import SwiftUI
import Carbon.HIToolbox
import Observation
import ApplicationServices

/// ⌥Space anywhere → a floating palette that asks the local AI a one-shot
/// question, with the user's current context (focused app, selected text,
/// recent clipboard, current paragraph) automatically attached.
///
/// Designed to be **the** "I'd reach for ChatGPT here" surface but local and
/// contextual: the user doesn't have to copy-paste the email/code/draft they
/// want help with — Halen sees what's on their screen already.
@MainActor
final class AskHalen: HalenPlugin {
    let id = "com.halen.ask-halen"
    let name = "Ask Halen"
    let summary = "⌥Space anywhere to ask your local AI with the page's context attached."
    let icon = "sparkles.rectangle.stack"
    let category: PluginCategory = .productivity

    private let services: HalenServices
    private weak var caretObserver: CaretObserver?

    private let hotkey = HotkeyRegistrar()
    private static let hotkeyId: UInt32 = 2   // VoiceDictation owns id=1

    private let state = AskHalenState()
    private var panel: NSPanel?
    private var inflightTask: Task<Void, Never>?

    init(services: HalenServices) {
        self.services = services
        self.caretObserver = services.caretObserver
    }

    func start() {
        let modifiers = UInt32(optionKey)
        let space = UInt32(kVK_Space)
        let ok = hotkey.register(keyCode: space, modifiers: modifiers, id: Self.hotkeyId) { [weak self] in
            MainActor.assumeIsolated { self?.togglePalette() }
        }
        if !ok {
            Log.warn("AskHalen: ⌥Space registration failed (another app may already own it)")
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
    /// the palette so the user's previous focus regains the keyboard.
    private func insertAtCaret() {
        guard !state.response.isEmpty,
              let element = state.context.focusedElement else {
            copyResponse()
            closePalette()
            return
        }
        closePalette()
        // Tiny delay so the palette has actually relinquished key-window.
        Task { @MainActor [caretObserver, response = state.response] in
            try? await Task.sleep(for: .milliseconds(80))
            // Use range length 0 — insert at the caret, don't replace.
            let range = NSRange(location: 0, length: 0)
            // Selection-set will likely fail (we don't know the real caret
            // offset). replaceRange's clipboard fallback handles it.
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
            Text("Press ⌥Space anywhere")
                .font(.system(.callout, weight: .medium))
            Text("A floating palette opens with your focused app, selected text, and recent clipboard already in context. Ask anything — Halen answers locally using whichever backend is active.")
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
