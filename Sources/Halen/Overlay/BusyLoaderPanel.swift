import AppKit
import SwiftUI

/// The 40×40 floating panel shown while a Gemma call is in flight — a
/// rotating cobalt arc around the Halen mark, plus a breathing-opacity
/// glow on the mark itself. Lives in a dedicated NSPanel so its extra
/// structure (auto-layout container + rotating sublayer) can't regress
/// the always-on caret indicator (`OverlayController.caretPanel`).
///
/// Pulled out of `OverlayController` for single-responsibility: this
/// class owns the panel's lifecycle (install → show/hide → teardown),
/// the ring + glow CALayer animations, and the busy-position maths.
/// `OverlayController` keeps the higher-level "when is the app busy"
/// counter + watchdog and asks this object to show/hide.
@MainActor
final class BusyLoaderPanel {
    /// Panel footprint. 40 pt is large enough to fit the 16 pt mark plus a
    /// 12 pt arc in the margin without clipping.
    static let size: CGFloat = 40

    /// CAAnimation key for the breathing-opacity glow on the centre logo.
    /// Stored as a constant so `addGlow` / `removeGlow` can't drift.
    private static let glowAnimationKey = "halen.busy.glow"

    private var panel: NSPanel?
    private var container: NSView?
    private var logo: NSHostingView<HalenCaretIndicator>?
    private var ringLayer: CAShapeLayer?

    /// Caller-supplied anchor for the next `show(at:)`. Caller updates this
    /// from `.inferenceActivity(.started)` payloads; the panel reads it on
    /// each show so a request that arrives with a more specific anchor than
    /// the caret can override the default placement.
    var pendingAnchor: Event.CaretRect?

    /// True iff the panel is currently visible on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    init() {}

    // MARK: - Lifecycle

    /// Build the floating panel + container + hosted logo. Idempotent —
    /// calling twice is a no-op so re-`start()`ing the overlay controller
    /// doesn't accumulate panels.
    func install() {
        guard panel == nil else { return }
        let busy = HalenFloatingPanel.make(
            size: NSSize(width: Self.size, height: Self.size),
            level: .statusBar,
            interactive: false,
            shadow: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true

        // The hosted logo always renders the "idle" mark (no severity tint).
        // A standalone OverlayIndicatorState reflects that — the busy loader
        // doesn't participate in finding signalling.
        let hosted = NSHostingView(rootView: HalenCaretIndicator(state: OverlayIndicatorState()))
        hosted.translatesAutoresizingMaskIntoConstraints = false
        hosted.sizingOptions = []
        hosted.wantsLayer = true
        view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hosted.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hosted.widthAnchor.constraint(equalToConstant: OverlayController.dotSize),
            hosted.heightAnchor.constraint(equalToConstant: OverlayController.dotSize),
        ])
        busy.contentView = view

        self.panel = busy
        self.container = view
        self.logo = hosted
    }

    /// Tear everything down. Called from `OverlayController.stop()` — the
    /// panel is orphaned afterwards; a future `install()` builds a fresh one.
    func teardown() {
        removeGlow()
        panel?.orderOut(nil)
        panel = nil
        container = nil
        logo = nil
        pendingAnchor = nil
    }

    // MARK: - Show / hide

    /// Position around `anchor` (or `pendingAnchor`, or fallback) and bring
    /// the panel up. Adds the rotating-ring + breathing-glow animations.
    /// Caller is responsible for first hiding the caret indicator so the
    /// two panels don't overlap.
    func show(at fallback: Event.CaretRect?) {
        guard let panel else { return }
        if let anchor = pendingAnchor ?? fallback {
            // Centre the 16×16 logo on what would have been the caret-
            // indicator position (just right of the anchor).
            let inset = (Self.size - OverlayController.dotSize) / 2
            let frame = NSRect(
                x: CGFloat(anchor.x) + 6 - inset,
                y: CGFloat(anchor.y) + (CGFloat(anchor.height) - OverlayController.dotSize) / 2 - inset,
                width: Self.size,
                height: Self.size
            )
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        addGlow()
    }

    /// Stop the animations and hide the panel. `pendingAnchor` is cleared
    /// so a stale anchor doesn't bleed into the next inference.
    func hide() {
        removeGlow()
        pendingAnchor = nil
        panel?.orderOut(nil)
    }

    // MARK: - Layers / animations

    private func addGlow() {
        guard let container, let layer = container.layer else { return }

        // Honors macOS "Reduce motion" — vestibular-disorder users get a
        // still cobalt dot in place of the spinning ring + breathing glow.
        // The hosted logo remains visible underneath, so "Halen is busy"
        // still reads visually; it just doesn't move.
        let reduceMotion = AccessibilityPreferences.shared.reduceMotion

        // Rotating cobalt arc in the margin around the logo.
        let ring = CAShapeLayer()
        ring.frame = container.bounds
        let diameter = OverlayController.dotSize + 12
        let ringRect = CGRect(
            x: (Self.size - diameter) / 2,
            y: (Self.size - diameter) / 2,
            width: diameter,
            height: diameter
        )
        ring.path = CGPath(ellipseIn: ringRect, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        // Alpha was 0.55 — marginal on the rendered material; 0.80 keeps the
        // spinner readable when the background blends toward grey (e.g. when
        // the busy panel is anchored over a light-text-on-light-surface app
        // like Pages or Notes). At 0.55 the cobalt arc dropped below WCAG AA
        // 3:1 non-text contrast against typical document backgrounds; 0.80
        // clears that bar comfortably without making the ring feel garish.
        ring.strokeColor = CGColor.halenCobalt.copy(alpha: 0.80)
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeStart = 0.0
        // With reduceMotion the ring becomes a full closed circle so the
        // missing arc-gap doesn't read like a broken/cropped indicator.
        ring.strokeEnd = reduceMotion ? 1.0 : 0.7
        if !reduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0.0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.0
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }
        layer.addSublayer(ring)
        ringLayer = ring

        // Breathing glow on the logo itself — opacity only, so its size is
        // untouched. Skipped entirely under reduceMotion; the logo stays at
        // full opacity instead of pulsing.
        if !reduceMotion, let logoLayer = logo?.layer {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1.0
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            logoLayer.add(pulse, forKey: Self.glowAnimationKey)
        }
    }

    private func removeGlow() {
        ringLayer?.removeFromSuperlayer()
        ringLayer = nil
        logo?.layer?.removeAnimation(forKey: Self.glowAnimationKey)
    }
}
