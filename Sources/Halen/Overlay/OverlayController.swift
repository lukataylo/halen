import AppKit
import SwiftUI

/// Two independent floating panels next to the focused text field:
///
///  - `caretPanel` — the always-on 16×16 Halen-logo caret indicator. Follows
///    `caret.moved`, auto-hides after a couple of seconds of inactivity. This
///    is deliberately the simplest possible structure (the SwiftUI logo *is*
///    the panel's content view) — it is the proven original and the busy-state
///    code must never touch it.
///  - `busyPanel` — a 40×40 "AI working" loader shown only while a Gemma call
///    is in flight (driven by `inference.activity`). A separate panel so its
///    extra structure (a container with a centered logo + a rotating ring)
///    can't regress the caret indicator.
///
/// User can turn the whole thing off via Settings → Cursor overlay.
@MainActor
final class OverlayController {
    private let eventBus: EventBus

    private var caretPanel: NSPanel?
    private var busyPanel: NSPanel?
    private var busyContainer: NSView?
    private var busyLogo: NSHostingView<HalenCaretIndicator>?
    private var ringLayer: CAShapeLayer?

    private var subscribeTask: Task<Void, Never>?
    /// Single auto-hide task. Each `caret.moved` pushes `hideDeadline` out;
    /// the running task picks it up on its next wake instead of being cancelled
    /// and respawned per event.
    private var hideTask: Task<Void, Never>?
    private var hideDeadline: Date?
    /// Last frame we set on `caretPanel`. Used to skip redundant `setFrame`
    /// calls when AX value-changed notifications fire without the cursor
    /// actually moving (very common during typing).
    private var lastCaretFrame: NSRect?
    private var defaultsObserver: NSObjectProtocol?

    /// In-flight inference calls. The loader stays up until this returns to 0.
    private var busyDepth = 0
    /// Most recent caret rect — fallback anchor for the loader.
    private var lastCaretRect: Event.CaretRect?
    /// Explicit anchor from the active inference source (e.g. a placeholder's
    /// on-screen bounds). Preferred over `lastCaretRect` while busy.
    private var busyAnchor: Event.CaretRect?

    private static let dotSize: CGFloat = 16
    private static let busySize: CGFloat = 40
    private static let glowKey = "halen.busy.glow"

    /// UserDefaults key. Read on every `showCaret()` so the toggle takes effect live.
    static let showDotKey = "halen.showOverlayDot"

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func start() {
        // Caret indicator: the SwiftUI logo is the content view directly — no
        // container, no offset subview. This is the proven original layout.
        let caret = Self.makePanel(size: Self.dotSize)
        caret.contentView = NSHostingView(rootView: HalenCaretIndicator())
        caretPanel = caret

        // Busy loader: a fixed 40×40 container with the 16×16 logo pinned dead
        // centre via Auto Layout (so NSHostingView sizing quirks can't shift
        // it) and room in the margin for the rotating ring sublayer.
        let busy = Self.makePanel(size: Self.busySize)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.busySize, height: Self.busySize))
        container.wantsLayer = true
        let logo = NSHostingView(rootView: HalenCaretIndicator())
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.sizingOptions = []
        logo.wantsLayer = true
        container.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: Self.dotSize),
            logo.heightAnchor.constraint(equalToConstant: Self.dotSize),
        ])
        busy.contentView = container
        busyPanel = busy
        busyContainer = container
        busyLogo = logo

        subscribeTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = payload.rect
                    // While busy, hold position — let the loader sit where it is.
                    if self.busyDepth == 0 {
                        self.showCaret(at: payload.rect)
                    }
                case .inferenceActivity(let payload):
                    switch payload.phase {
                    case .started:
                        if let anchor = payload.anchor { self.busyAnchor = anchor }
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
                    self.caretPanel?.orderOut(nil)
                    self.busyPanel?.orderOut(nil)
                }
            }
        }
    }

    func stop() {
        subscribeTask?.cancel()
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        lastCaretFrame = nil
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        busyDepth = 0
        removeGlow()
        caretPanel?.orderOut(nil)
        busyPanel?.orderOut(nil)
        caretPanel = nil
        busyPanel = nil
    }

    static var indicatorEnabled: Bool {
        UserDefaults.standard.object(forKey: showDotKey) as? Bool ?? true
    }

    private static func makePanel(size: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
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
        return panel
    }

    // MARK: - Caret indicator (the proven original)

    private func showCaret(at caret: Event.CaretRect) {
        guard Self.indicatorEnabled, let panel = caretPanel else { return }
        // Just right of the caret, vertically centered on it.
        let frame = NSRect(
            x: CGFloat(caret.x) + 6,
            y: CGFloat(caret.y) + (CGFloat(caret.height) - Self.dotSize) / 2,
            width: Self.dotSize,
            height: Self.dotSize
        )
        // Skip the reframe + sync redraw if the cursor hasn't actually moved.
        // `display: false` lets AppKit coalesce the next paint with the natural
        // run-loop tick instead of forcing a synchronous draw on every keystroke.
        if frame != lastCaretFrame {
            panel.setFrame(frame, display: false)
            lastCaretFrame = frame
        }
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        // Push the deadline out. If a hide task is already running, it will
        // observe the new deadline on its next wake and re-sleep — no need to
        // cancel and respawn a fresh `Task` per `caret.moved` event.
        let deadline = Date().addingTimeInterval(2)
        hideDeadline = deadline
        if hideTask != nil { return }
        hideTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let target = self.hideDeadline else { return }
                let remaining = target.timeIntervalSinceNow
                if remaining <= 0 {
                    self.caretPanel?.orderOut(nil)
                    self.lastCaretFrame = nil   // next show must re-set the frame
                    self.hideTask = nil
                    self.hideDeadline = nil
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    // MARK: - Busy loader (separate panel)

    /// Enter the "AI working" state: hand off from the caret indicator to the
    /// loader panel, anchored at the inference source's location.
    private func enterBusy() {
        guard Self.indicatorEnabled, let busyPanel else { return }
        // Cancel + clear so the next `scheduleAutoHide` after exitBusy spawns
        // a fresh task instead of seeing the stale (cancelled) reference.
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        caretPanel?.orderOut(nil)
        lastCaretFrame = nil

        if let anchor = busyAnchor ?? lastCaretRect {
            // Position so the centered 16×16 logo lands where the caret
            // indicator would have — just right of the anchor.
            let inset = (Self.busySize - Self.dotSize) / 2
            let frame = NSRect(
                x: CGFloat(anchor.x) + 6 - inset,
                y: CGFloat(anchor.y) + (CGFloat(anchor.height) - Self.dotSize) / 2 - inset,
                width: Self.busySize,
                height: Self.busySize
            )
            busyPanel.setFrame(frame, display: true)
        }
        busyPanel.orderFrontRegardless()
        addGlow()
    }

    /// Leave the busy state: hide the loader and hand back to the caret indicator.
    private func exitBusy() {
        removeGlow()
        busyAnchor = nil
        busyPanel?.orderOut(nil)
        if let caret = lastCaretRect {
            showCaret(at: caret)
        }
    }

    private func addGlow() {
        guard let container = busyContainer, let layer = container.layer else { return }

        // Rotating cobalt arc in the margin around the logo.
        let ring = CAShapeLayer()
        ring.frame = container.bounds
        let diameter = Self.dotSize + 12
        let ringRect = CGRect(
            x: (Self.busySize - diameter) / 2,
            y: (Self.busySize - diameter) / 2,
            width: diameter,
            height: diameter
        )
        ring.path = CGPath(ellipseIn: ringRect, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = CGColor.halenCobalt.copy(alpha: 0.55)
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
        layer.addSublayer(ring)
        ringLayer = ring

        // Breathing glow on the logo itself — opacity only, so its size is untouched.
        if let logoLayer = busyLogo?.layer {
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
        busyLogo?.layer?.removeAnimation(forKey: Self.glowKey)
    }
}

/// Small solid cobalt-blue Halen mark used as the caret indicator. Source is
/// `HalenIndicator.png` (rendered from `Resources/HalenSolid.svg`), already
/// the right colour — no SwiftUI tinting needed. Falls back to a coloured
/// circle if the asset isn't bundled.
private struct HalenCaretIndicator: View {
    var body: some View {
        Group {
            if let img = NSImage(named: "HalenIndicator") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle()
                    .fill(Color.halenCobalt)
                    .padding(2)
            }
        }
        .shadow(color: Color.halenCobalt.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}
