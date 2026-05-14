import AppKit
import SwiftUI

/// Shows a small Halen-logo indicator next to the caret of the focused text
/// field. Follows `caret.moved` events; hides itself after a couple of seconds
/// of caret inactivity. User can turn it off via Settings → Cursor overlay.
///
/// While a Gemma-backed plugin is mid-call it shows a "busy" loader — the logo
/// glows and gains a rotating ring — driven by `inference.activity` events.
///
/// The panel is a fixed `panelSize` square; the SwiftUI logo is a fixed
/// `logoSize` square centered inside it. The busy ring is a CoreAnimation
/// sublayer that appears in the surrounding margin — the logo itself never
/// changes size, and its SwiftUI view is never restructured.
@MainActor
final class OverlayController {
    private let eventBus: EventBus
    private var window: NSPanel?
    private var containerView: NSView?
    private var hostingView: NSHostingView<HalenCaretIndicator>?
    private var subscribeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    /// In-flight inference calls. The loader stays up until this returns to 0.
    private var busyDepth = 0
    /// Most recent caret rect — anchors the loader if it appears mid-flight.
    private var lastCaretRect: Event.CaretRect?
    /// The rotating ring sublayer added while busy.
    private var ringLayer: CAShapeLayer?

    /// The visible Halen mark — fixed size, never scales.
    private static let logoSize: CGFloat = 16
    /// The panel/container square; the margin around the logo is the room the
    /// busy ring needs.
    private static let panelSize: CGFloat = 40
    private static let glowKey = "halen.busy.glow"
    private static let cobalt = CGColor(red: 0.0, green: 0.30, blue: 0.99, alpha: 1.0)

    /// UserDefaults key. Read on every `show()` so the toggle takes effect live.
    static let showDotKey = "halen.showOverlayDot"

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func start() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize),
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

        // Fixed-size container; the logo sits centered inside it so the busy
        // ring has margin to draw into without ever resizing the logo.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize))
        container.wantsLayer = true
        let inset = (Self.panelSize - Self.logoSize) / 2
        let hosting = NSHostingView(rootView: HalenCaretIndicator())
        hosting.frame = NSRect(x: inset, y: inset, width: Self.logoSize, height: Self.logoSize)
        hosting.autoresizingMask = []
        hosting.wantsLayer = true
        container.addSubview(hosting)
        panel.contentView = container

        window = panel
        containerView = container
        hostingView = hosting

        subscribeTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = payload.rect
                    // While busy, hold position — let the loader sit where it is.
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
        removeGlow()
        window?.orderOut(nil)
        window = nil
    }

    static var indicatorEnabled: Bool {
        UserDefaults.standard.object(forKey: showDotKey) as? Bool ?? true
    }

    /// Panel frame that places the centered logo just to the right of the caret,
    /// vertically centered on it.
    private func frame(for caret: Event.CaretRect) -> NSRect {
        let inset = (Self.panelSize - Self.logoSize) / 2
        return NSRect(
            x: CGFloat(caret.x) + 6 - inset,
            y: CGFloat(caret.y) + (CGFloat(caret.height) - Self.panelSize) / 2,
            width: Self.panelSize,
            height: Self.panelSize
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

    // MARK: - Busy loader

    /// Enter the "AI working" state: pin the panel at the caret, keep it
    /// visible, and add the glow + rotating ring around the (unchanged) logo.
    private func enterBusy() {
        guard Self.indicatorEnabled, let window else { return }
        hideTask?.cancel()
        if let caret = lastCaretRect {
            window.setFrame(frame(for: caret), display: true)
        }
        window.orderFrontRegardless()
        addGlow()
    }

    /// Leave the busy state: drop the glow + ring and resume the auto-hide.
    private func exitBusy() {
        removeGlow()
        scheduleAutoHide()
    }

    private func addGlow() {
        guard let container = containerView, let containerLayer = container.layer else { return }

        // Rotating cobalt arc in the margin around the logo.
        let ring = CAShapeLayer()
        ring.frame = container.bounds
        let diameter = Self.logoSize + 12
        let ringRect = CGRect(
            x: (Self.panelSize - diameter) / 2,
            y: (Self.panelSize - diameter) / 2,
            width: diameter,
            height: diameter
        )
        ring.path = CGPath(ellipseIn: ringRect, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Self.cobalt.copy(alpha: 0.55)
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeStart = 0.0
        ring.strokeEnd = 0.7
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.0
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
        containerLayer.addSublayer(ring)
        ringLayer = ring

        // Breathing glow on the logo itself — opacity only, so its size is untouched.
        if let logoLayer = hostingView?.layer {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1.0
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            logoLayer.add(pulse, forKey: Self.glowKey)
        }
    }

    private func removeGlow() {
        ringLayer?.removeFromSuperlayer()
        ringLayer = nil
        hostingView?.layer?.removeAnimation(forKey: Self.glowKey)
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
