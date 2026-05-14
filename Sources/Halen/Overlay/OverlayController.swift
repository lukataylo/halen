import AppKit

/// Shows a small Halen-logo indicator next to the caret of the focused text
/// field. Follows `caret.moved` events; hides itself after a couple of seconds
/// of caret inactivity. User can turn it off via Settings → Cursor overlay.
///
/// While a Gemma-backed plugin is mid-call it shows a "busy" state — the mark
/// pulses and stays put — driven by `inference.activity` events on the bus.
///
/// Uses a plain layer-backed `NSImageView`, not an `NSHostingView`: the
/// indicator is a single 16×16 image and AppKit renders it reliably, with none
/// of the SwiftUI hosting-view sizing quirks.
@MainActor
final class OverlayController {
    private let eventBus: EventBus
    private var window: NSPanel?
    private var imageView: NSImageView?
    private var subscribeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    /// Number of in-flight inference calls. The indicator stays busy until this
    /// returns to 0, so overlapping expansions don't revert it prematurely.
    private var busyDepth = 0
    /// Most recent caret rect seen on the bus — anchors the busy indicator even
    /// if no fresh `caret.moved` arrives.
    private var lastCaretRect: Event.CaretRect?

    private static let dotSize: CGFloat = 16
    private static let busyAnimationKey = "halen.busy.pulse"

    /// UserDefaults key. Read on every `show()` so the toggle takes effect live.
    static let showDotKey = "halen.showOverlayDot"

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func start() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize),
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

        let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize))
        iv.image = NSImage(named: "HalenIndicator")
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageFrameStyle = .none
        iv.autoresizingMask = [.width, .height]
        iv.wantsLayer = true
        panel.contentView = iv

        window = panel
        imageView = iv

        subscribeTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = payload.rect
                    // While busy, hold position — the placeholder write and the
                    // final response write both fire `caret.moved`, and chasing
                    // them makes the indicator jump around.
                    if self.busyDepth == 0 {
                        self.show(at: payload.rect)
                    }
                case .inferenceActivity(let payload):
                    switch payload.phase {
                    case .started:
                        self.busyDepth += 1
                        if self.busyDepth == 1 { self.enterBusy() }
                    case .finished:
                        self.busyDepth = max(0, self.busyDepth - 1)
                        if self.busyDepth == 0 { self.exitBusy() }
                    }
                default:
                    break
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
        busyDepth = 0
        imageView?.layer?.removeAnimation(forKey: Self.busyAnimationKey)
        window?.orderOut(nil)
        window = nil
        imageView = nil
    }

    static var indicatorEnabled: Bool {
        UserDefaults.standard.object(forKey: showDotKey) as? Bool ?? true
    }

    /// Indicator frame: just to the right of the caret, vertically centered on it.
    private func frame(for caret: Event.CaretRect) -> NSRect {
        NSRect(
            x: caret.x + 6,
            y: caret.y + (caret.height - Self.dotSize) / 2,
            width: Self.dotSize,
            height: Self.dotSize
        )
    }

    private func show(at caret: Event.CaretRect) {
        guard Self.indicatorEnabled, let window else { return }
        window.setFrame(frame(for: caret), display: true)
        window.orderFrontRegardless()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.window?.orderOut(nil)
        }
    }

    /// Enter the "working" state: keep the indicator visible and pulsing,
    /// anchored at the last known caret position, with no auto-hide.
    private func enterBusy() {
        guard Self.indicatorEnabled, let window, let caret = lastCaretRect else {
            if lastCaretRect == nil {
                Log.debug("OverlayController: enterBusy with no known caret rect — skipping visual")
            }
            return
        }
        hideTask?.cancel()
        window.setFrame(frame(for: caret), display: true)
        addBusyPulse()
        window.orderFrontRegardless()
    }

    /// Leave the "working" state: stop pulsing and resume the normal auto-hide.
    private func exitBusy() {
        imageView?.layer?.removeAnimation(forKey: Self.busyAnimationKey)
        scheduleAutoHide()
    }

    /// A breathing opacity pulse on the indicator's layer — clearly reads as
    /// "working" without touching geometry (no anchor-point pitfalls).
    private func addBusyPulse() {
        guard let layer = imageView?.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.4
        pulse.toValue = 1.0
        pulse.duration = 0.65
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.busyAnimationKey)
    }
}
