import AppKit
import SwiftUI

/// Shows a small blue dot next to the caret of the focused text field. The dot follows
/// `caret.moved` events from `CaretObserver`. Hides itself if no caret event fires for
/// a couple of seconds (i.e., the user is not in a text field).
///
/// The window is a non-activating, click-through panel at floating level so it appears
/// above all app windows but never steals focus or swallows clicks.
@MainActor
final class OverlayController {
    private let eventBus: EventBus
    private var window: NSPanel?
    private var subscribeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func start() {
        let dotSize: CGFloat = 16
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: dotSize, height: dotSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar  // above .floating so it sits over menubar-adjacent surfaces too
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayDot())

        window = panel

        subscribeTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                if case .caretMoved(let payload) = event {
                    self.show(at: CGPoint(x: payload.rect.x, y: payload.rect.y),
                              caretHeight: payload.rect.height)
                }
            }
        }
    }

    func stop() {
        subscribeTask?.cancel()
        hideTask?.cancel()
        window?.orderOut(nil)
        window = nil
    }

    private func show(at caretOrigin: CGPoint, caretHeight: Double) {
        guard let window else { return }

        // Place dot just to the right of the caret, vertically centered on it.
        let dotSize: CGFloat = 12
        let frame = NSRect(
            x: caretOrigin.x + 6,
            y: caretOrigin.y + (caretHeight - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.window?.orderOut(nil)
        }
    }
}

private struct OverlayDot: View {
    var body: some View {
        Circle()
            .fill(Color.blue)
            .overlay(
                Circle().stroke(.white.opacity(0.9), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
    }
}
