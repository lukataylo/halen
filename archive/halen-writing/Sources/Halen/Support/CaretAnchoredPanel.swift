import AppKit

/// Caret-anchored placement for transient overlay panels — resolves *where* to
/// float a popover relative to the user's text caret, trying progressively
/// coarser Accessibility sources so apps with poor AX support (Electron, web
/// text fields, Notion) still get a popover near their text rather than a
/// screen-corner pin.
///
/// Lifted verbatim out of `SentimentGuard` so the popover-driven writing
/// plugins — Sentiment Guard, Clarity Checker, Style Guide — share one
/// implementation instead of copy-pasting ~100 lines of anchor maths.
@MainActor
enum CaretAnchoredPanel {

    /// A resolved anchor. The *kind* of region changes the placement strategy
    /// (a caret gets a popup directly below it; an element/window anchor gets
    /// the popup near the field's content area).
    struct Anchor {
        let rect: CGRect
        let kind: Kind
        enum Kind { case caret, element, window }
    }

    /// Resolve where to anchor a popover. `cachedCaretRect` is the most recent
    /// `caret.moved` rect the caller has seen (plugins that track it pass it
    /// in); pass `nil` when unavailable.
    ///
    /// Each step's rect is validated against the screen list because some apps
    /// misreport AX bounds in window-local coords; pinning to those would put
    /// the popup at (0,0).
    static func resolveAnchor(caretObserver: CaretObserver?,
                              cachedCaretRect: CGRect?) -> Anchor? {
        // 1. Exact caret bounds — the ideal: popup pops right below the caret.
        if let element = caretObserver?.currentElement,
           let axRect = axReadCaretBounds(element) {
            let cocoa = axRectToCocoa(axRect)
            if rectIsOnScreen(cocoa) { return Anchor(rect: cocoa, kind: .caret) }
        }
        // 2. Cached caret rect from the most recent caret.moved event.
        if let cached = cachedCaretRect, cached.width > 0 || cached.height > 0,
           rectIsOnScreen(cached) {
            return Anchor(rect: cached, kind: .caret)
        }
        // 3. The focused element's frame. Electron / web text fields refuse to
        //    expose caret bounds but almost always expose AXFrame on the field.
        if let element = caretObserver?.currentElement,
           let axFrame = axReadFrame(element) {
            let cocoa = axRectToCocoa(axFrame)
            if rectIsOnScreen(cocoa) { return Anchor(rect: cocoa, kind: .element) }
        }
        // 4. The containing window's frame — last resort: at minimum we land on
        //    the app the user is in, not a different display's corner.
        if let element = caretObserver?.currentElement,
           let axWindow = axReadContainingWindowFrame(element) {
            let cocoa = axRectToCocoa(axWindow)
            if rectIsOnScreen(cocoa) { return Anchor(rect: cocoa, kind: .window) }
        }
        return nil
    }

    static func rectIsOnScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains(where: { $0.frame.intersects(rect) })
    }

    /// Resolve which screen the caret sits on. Uses `contains(point)` on the
    /// anchor's centre rather than `intersects(rect)` — a zero-width caret is
    /// `CGRectIsEmpty`, which fails the intersect test against every screen.
    private static func screenContaining(_ anchor: CGRect) -> NSScreen? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
    }

    /// Place a panel of `size` near `anchor`, clamped into the `visibleFrame`
    /// of the screen that actually contains it. Anchor kind changes placement:
    ///   - `.caret`: 10 px below the caret (flips above if no room below).
    ///   - `.element`: near the field's upper content area.
    ///   - `.window`: nestled in the window's bottom-left inset.
    /// With no anchor at all it lands at the centre of the main screen, never
    /// the corner (a corner reads as "system notification" — wrong model).
    static func frame(for anchor: Anchor?, size: CGSize) -> NSRect {
        if let anchor, let screen = screenContaining(anchor.rect) {
            let visible = screen.visibleFrame
            var x = anchor.rect.minX
            var y: CGFloat
            switch anchor.kind {
            case .caret:
                let below = anchor.rect.minY - size.height - 10
                let above = anchor.rect.maxY + 10
                y = (below >= visible.minY + 8) ? below : above
            case .element:
                x = anchor.rect.minX + 12
                y = anchor.rect.maxY - size.height - 44
            case .window:
                x = anchor.rect.minX + 24
                y = anchor.rect.minY + 24
            }
            x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
            y = min(max(visible.minY + 8, y), visible.maxY - size.height - 8)
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            return NSRect(x: f.midX - size.width / 2,
                          y: f.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        return NSRect(x: 200, y: 200, width: size.width, height: size.height)
    }
}
