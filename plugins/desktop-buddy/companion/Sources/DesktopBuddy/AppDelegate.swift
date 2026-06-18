import Cocoa
import SwiftUI

/// Top-level glue between the bridge (NDJSON to plugin.py) and the two
/// floating windows (buddy + bubble). State changes from incoming messages
/// run on the main thread; user actions (clicks, submits, dismisses) are
/// forwarded back over the bridge.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let bridge = Bridge()
    private let buddyModel = BuddyModel()
    private let bubbleModel = BubbleModel()

    private var buddyWindow: BuddyWindow!
    private var bubbleWindow: BubbleWindow!

    private var sayTimer: Timer?
    private var expressionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buddyWindow = BuddyWindow(model: buddyModel) { [weak self] in
            self?.bridge.send(["type": "clicked"])
        }
        buddyWindow.orderFrontRegardless()

        bubbleWindow = BubbleWindow(
            model: bubbleModel,
            onSubmit: { [weak self] text in self?.handleSubmit(text: text) },
            onClose:  { [weak self] in self?.hideBubble(notifyPlugin: true) }
        )

        bridge.onMessage = { [weak self] msg in self?.handle(message: msg) }
        bridge.start()
        bridge.send(["type": "ready"])
    }

    // MARK: - Bridge inbound

    private func handle(message: [String: Any]) {
        guard let kind = message["type"] as? String else { return }
        switch kind {
        case "expression":
            applyExpression(message)
        case "say":
            applySay(message)
        case "hideBubble":
            hideBubble(notifyPlugin: false)
        case "focus":
            openInputBubble(message)
        case "showReply":
            applyReply(message)
        case "shutdown":
            NSApp.terminate(nil)
        default:
            bridge.log("buddy/companion: unknown message kind: \(kind)")
        }
    }

    private func applyExpression(_ msg: [String: Any]) {
        guard let raw = msg["state"] as? String,
              let expr = Expression(rawValue: raw) else { return }
        expressionTimer?.invalidate()
        buddyModel.expression = expr
        if let ttl = msg["ttlMs"] as? Double, ttl > 0 {
            // Auto-revert to neutral after the ttl elapses — used for
            // transient cues like "thinking" or a tone reaction.
            expressionTimer = Timer.scheduledTimer(withTimeInterval: ttl / 1000.0, repeats: false) { [weak self] _ in
                self?.buddyModel.expression = .neutral
            }
        }
    }

    private func applySay(_ msg: [String: Any]) {
        let text = (msg["text"] as? String) ?? ""
        let isError = (msg["error"] as? Bool) ?? false
        let ttl = (msg["ttlMs"] as? Double) ?? 8000
        showBubble(mode: .say(text, isError: isError), autoHideMs: ttl)
    }

    private func applyReply(_ msg: [String: Any]) {
        // Same shape as `say`, but defaults to a longer dwell since a chat
        // reply is something the user wants to read.
        let text = (msg["text"] as? String) ?? ""
        let isError = (msg["error"] as? Bool) ?? false
        let ttl = (msg["ttlMs"] as? Double) ?? 16000
        showBubble(mode: .say(text, isError: isError), autoHideMs: ttl)
    }

    private func openInputBubble(_ msg: [String: Any]) {
        let modeStr = (msg["mode"] as? String) ?? "chat"
        let mode = InputMode(rawValue: modeStr) ?? .chat
        showBubble(mode: .input(mode), autoHideMs: nil)
        // Make the bubble key so its text field receives keystrokes, but do
        // NOT activate the companion app: it's a `.nonactivatingPanel` with
        // `canBecomeKey == true`, so it can host the key view chain while the
        // user's app stays frontmost. Activating here would steal focus, which
        // makes the host's CaretObserver rebind AX to this companion and the
        // ⌃⌥B "rewrite the selection" path then reads/writes the wrong field.
        bubbleWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.bubbleModel.focusInput = true
        }
    }

    // MARK: - Bubble lifecycle

    private func showBubble(mode: BubbleModel.Mode, autoHideMs: Double?) {
        sayTimer?.invalidate()
        bubbleModel.mode = mode
        bubbleWindow.anchor(to: buddyWindow)
        bubbleWindow.orderFrontRegardless()
        if let ms = autoHideMs, ms > 0 {
            sayTimer = Timer.scheduledTimer(withTimeInterval: ms / 1000.0, repeats: false) { [weak self] _ in
                self?.hideBubble(notifyPlugin: false)
            }
        }
    }

    private func hideBubble(notifyPlugin: Bool) {
        sayTimer?.invalidate()
        sayTimer = nil
        bubbleModel.mode = .hidden
        bubbleModel.draft = ""
        bubbleModel.focusInput = false
        bubbleWindow.orderOut(nil)
        if notifyPlugin {
            bridge.send(["type": "closed"])
        }
    }

    // MARK: - User actions

    private func handleSubmit(text: String) {
        // Mode is implicit from the current bubble state.
        let mode: String = {
            if case .input(let m) = bubbleModel.mode { return m.rawValue }
            return "chat"
        }()
        bridge.send(["type": "submit", "text": text, "mode": mode])
        // Show a placeholder until the reply comes back. plugin.py will
        // overwrite this with `showReply` when inference completes.
        showBubble(mode: .say("Thinking…", isError: false), autoHideMs: 60000)
    }
}
