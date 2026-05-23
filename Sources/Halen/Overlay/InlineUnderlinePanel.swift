import AppKit

/// Preview-feature inline underline for active findings. When the user
/// enables "Inline underlines (preview)" in Settings, this panel draws a
/// 3 pt severity-coloured strip *under* the flagged paragraph instead of
/// (or in addition to) the cursor-indicator tint that's the v1 surface.
///
/// ── Scope of this v1 ──────────────────────────────────────────────────────
/// Single rectangle anchored to the finding's whole-paragraph rect (the
/// `Event.FindingDetected.anchor`). That's a deliberately *coarse*
/// approximation — Word/Grammarly-style per-glyph underlines need
/// `AXBoundsForRange` over the flagged sub-string plus tracking on every
/// scroll / reflow / font change, which is a multi-day arc tracked
/// elsewhere. v1 ships the toggle + the visible affordance so we can
/// dogfood the UX paradigm before committing to that engineering lift.
///
/// Visual semantics:
///   - red    (`.tone`)        — Sentiment Guard flagged the paragraph.
///   - orange (`.conciseness`) — Sentiment Guard wordy/filler match.
///   - amber  (`.clarity`)     — Clarity Checker rule match.
///
/// Like `BusyLoaderPanel`, the panel is non-interactive (clicks pass
/// through to the underlying app) — the click target stays on the caret
/// indicator. Underline is purely a *signal* in this iteration.
@MainActor
final class InlineUnderlinePanel {
    /// Underline thickness (pt). 3 pt is wide enough to read at a glance
    /// without obscuring descenders on most font sizes.
    private static let thickness: CGFloat = 3
    /// Vertical offset below the anchor's `minY`. Negative pushes the
    /// strip *below* the line of text; positive would draw it through.
    private static let verticalOffsetBelowAnchor: CGFloat = -2

    private var panel: NSPanel?
    private var stripLayer: CALayer?

    /// True iff the panel is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    init() {}

    // MARK: - Lifecycle

    /// Build the floating panel + its tinted strip sublayer. Idempotent.
    func install() {
        guard panel == nil else { return }
        let p = HalenFloatingPanel.make(
            // Initial size is a placeholder; `show(at:severity:)` always
            // overwrites the frame before the panel becomes visible.
            size: NSSize(width: 100, height: Self.thickness),
            level: .statusBar,
            interactive: false,
            shadow: false
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: Self.thickness))
        host.wantsLayer = true
        let strip = CALayer()
        strip.frame = host.bounds
        strip.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        strip.cornerRadius = Self.thickness / 2
        host.layer?.addSublayer(strip)
        p.contentView = host

        self.panel = p
        self.stripLayer = strip
    }

    /// Remove the panel from the screen and forget it. A subsequent
    /// `install()` rebuilds.
    func teardown() {
        panel?.orderOut(nil)
        panel = nil
        stripLayer = nil
    }

    // MARK: - Show / hide

    /// Position a `thickness`-pt strip across the width of `anchor` and
    /// recolour it for `severity`. Clamped to the anchor's host screen so
    /// a finding whose anchor straddles a display edge still lands
    /// somewhere visible.
    func show(at anchor: Event.CaretRect, severity: Event.FindingDetected.Severity) {
        guard let panel, let stripLayer else { return }
        let clamped = Self.clamp(
            origin: CGPoint(x: anchor.x,
                            y: anchor.y + Self.verticalOffsetBelowAnchor),
            width: max(anchor.width, 20),
            thickness: Self.thickness)
        panel.setFrame(NSRect(origin: clamped.origin,
                              size: NSSize(width: clamped.width, height: Self.thickness)),
                       display: true)
        stripLayer.frame = CGRect(origin: .zero,
                                  size: CGSize(width: clamped.width, height: Self.thickness))
        // `CGColor` is what `CALayer.backgroundColor` wants — bridge via NSColor
        // so the colour exactly matches the dot used on the caret indicator.
        stripLayer.backgroundColor = Self.color(for: severity).cgColor
        panel.orderFrontRegardless()
    }

    /// Take the strip down. Caller invokes on `findingsCleared`, app switch,
    /// or when the toggle flips off.
    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Helpers

    /// Clamp `(origin, width)` to the visible frame of the screen that
    /// contains the origin's centre — never draw outside any screen,
    /// otherwise macOS happily creates an unreachable panel.
    private static func clamp(origin: CGPoint, width: CGFloat,
                              thickness: CGFloat) -> (origin: CGPoint, width: CGFloat) {
        let centre = CGPoint(x: origin.x + width / 2, y: origin.y + thickness / 2)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return (origin, width) }
        let maxX = visible.maxX - 4
        let minX = visible.minX + 4
        let cappedX = min(max(minX, origin.x), maxX)
        let cappedWidth = min(width, maxX - cappedX)
        let cappedY = min(max(visible.minY + 4, origin.y),
                          visible.maxY - thickness - 4)
        return (CGPoint(x: cappedX, y: cappedY), cappedWidth)
    }

    /// Colour matches the cursor-indicator tint for the same severity so
    /// the two surfaces read as one signal language.
    private static func color(for severity: Event.FindingDetected.Severity) -> NSColor {
        switch severity {
        case .clarity:     return NSColor(red: 0.93, green: 0.78, blue: 0.20, alpha: 1)
        case .conciseness: return NSColor(red: 0.96, green: 0.55, blue: 0.10, alpha: 1)
        case .tone:        return NSColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1)
        }
    }
}
