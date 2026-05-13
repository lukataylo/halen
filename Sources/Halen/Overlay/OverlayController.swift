import AppKit
import SwiftUI

/// Shows a small Halen-logo indicator next to the caret of the focused text
/// field. Follows `caret.moved` events; hides itself after a couple of seconds
/// of caret inactivity. User can turn it off via Settings → Cursor overlay.
@MainActor
final class OverlayController {
    private let eventBus: EventBus
    private var window: NSPanel?
    private var subscribeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    /// UserDefaults key. Read on every `show()` so the toggle takes effect live.
    static let showDotKey = "halen.showOverlayDot"

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
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HalenCaretIndicator())

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

        // Hide instantly if the user disables the indicator in Settings.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !Self.indicatorEnabled {
                    self.window?.orderOut(nil)
                }
            }
        }
    }

    func stop() {
        subscribeTask?.cancel()
        hideTask?.cancel()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        window?.orderOut(nil)
        window = nil
    }

    static var indicatorEnabled: Bool {
        UserDefaults.standard.object(forKey: showDotKey) as? Bool ?? true
    }

    private func show(at caretOrigin: CGPoint, caretHeight: Double) {
        guard Self.indicatorEnabled, let window else { return }

        // Place the indicator just to the right of the caret, vertically centered on it.
        let dotSize: CGFloat = 16
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

/// Small solid cobalt-blue Halen mark used as the caret indicator. Source is
/// `HalenIndicator.png` (rendered from `Resources/HalenSolid.svg`), already
/// the right colour — no SwiftUI tinting needed. Falls back to a coloured
/// circle if the asset isn't bundled.
private struct HalenCaretIndicator: View {
    private static let cobalt = Color(red: 0.0, green: 0.30, blue: 0.99)

    var body: some View {
        Group {
            if let img = NSImage(named: "HalenIndicator") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle()
                    .fill(Self.cobalt)
                    .padding(2)
            }
        }
        .shadow(color: Self.cobalt.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}
