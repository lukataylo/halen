import AppKit
import ApplicationServices

/// Hard ceiling on how long any single AX call may block. Without this every
/// `AXUIElementCopyAttributeValue*` runs synchronously on the calling thread
/// — and we call them from the main thread, so a frozen Electron renderer or
/// a slow screen-reader bridge can wedge the whole UI. The system default is
/// 6 s, which is plenty of time for the user to feel "Halen is broken." 500 ms
/// is short enough that a hung app shaves to half a second and long enough
/// that legitimate writes (the slowest path; replacing 4 KB in a slow renderer
/// can hit ~150 ms) have plenty of headroom — typical AX reads finish in <5 ms.
///
/// Apple-blessed mechanism: setting the timeout on the system-wide AX element
/// establishes a process default; setting it on an app element overrides for
/// that app. Children inherit from their app. We do both — global at startup,
/// per-app on focus change — so no AX call can outrun the budget.
let axMessagingTimeoutSeconds: Float = 0.5

/// Apply `axMessagingTimeoutSeconds` as the process-wide default. Call once
/// from `AppCoordinator.start()`. Safe to call again; `AXUIElementSetMessagingTimeout`
/// is idempotent.
func axInstallGlobalMessagingTimeout() {
    let systemWide = AXUIElementCreateSystemWide()
    let status = AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeoutSeconds)
    if status != .success {
        Log.warn("AX: AXUIElementSetMessagingTimeout (system-wide) returned \(status.rawValue)")
    }
}

/// Apply the timeout to a specific app element. Child elements (focused field,
/// windows) inherit from the app. Call from `CaretObserver.switchToApp` after
/// `AXUIElementCreateApplication`. Errors are logged but non-fatal — the
/// global timeout is the backstop.
func axApplyMessagingTimeout(to element: AXUIElement) {
    _ = AXUIElementSetMessagingTimeout(element, axMessagingTimeoutSeconds)
}

/// Read a string-valued AX attribute, returning `nil` if absent or wrong type.
func axReadString(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard result == .success, let v = value as? String else { return nil }
    return v
}

/// Read the focused UI element from an application element.
func axReadFocusedElement(_ appElement: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
    // `value` comes from arbitrary third-party AX trees, so the `CFGetTypeID`
    // check IS the type guard. The `as!` that follows cannot trap: for a CF
    // type the compiler treats the downcast as unconditional ("always
    // succeeds"), and `CFGetTypeID` has already confirmed the dynamic type.
    guard result == .success, let v = value,
          CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    let element: AXUIElement = v as! AXUIElement
    return element
}

/// Read `kAXSelectedTextRangeAttribute` as a `CFRange` (location is the caret offset when length == 0).
func axReadSelectedRange(_ element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var range = CFRange(location: 0, length: 0)
    // Safe: `CFGetTypeID` above confirmed the AXValue type; the CF `as!` is
    // an unconditional, non-trapping reinterpretation.
    AXValueGetValue(v as! AXValue, .cfRange, &range)
    return range
}

/// Read the currently selected text via `kAXSelectedTextAttribute`. Returns
/// an empty string when there is no selection (caret only) — callers should
/// pair this with `axReadSelectedRange` and check the range length to tell
/// "nothing selected" apart from "selection is genuinely empty".
func axReadSelectedText(_ element: AXUIElement) -> String {
    axReadString(element, kAXSelectedTextAttribute) ?? ""
}

/// On-screen bounding rect of an arbitrary text range via
/// `kAXBoundsForRangeParameterizedAttribute`. Rect is in AX coordinates
/// (top-left origin, primary-display space) — use `axRectToCocoa` to convert.
func axReadBounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
    var cfRange = range
    guard let axRange: AXValue = withUnsafePointer(to: &cfRange, { ptr in
        AXValueCreate(.cfRange, UnsafeRawPointer(ptr))
    }) else { return nil }

    var boundsRef: CFTypeRef?
    let r = AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        axRange,
        &boundsRef
    )
    guard r == .success, let v = boundsRef, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    // Safe: see `axReadSelectedRange` — `CFGetTypeID` is the guard.
    AXValueGetValue(v as! AXValue, .cgRect, &rect)
    return rect
}

/// Resolve the on-screen bounding rect of the caret (a zero-length range at the
/// current caret offset). See `axReadBounds`.
func axReadCaretBounds(_ element: AXUIElement) -> CGRect? {
    guard let selection = axReadSelectedRange(element) else { return nil }
    return axReadBounds(element, range: CFRange(location: selection.location, length: 0))
}

/// Read the on-screen frame of an arbitrary AX element via
/// `kAXFrameAttribute`. Useful when `kAXBoundsForRangeParameterizedAttribute`
/// isn't supported by the element (Electron, most browser text fields) and
/// we just need *somewhere reasonable* to anchor UI relative to the field
/// the user is typing in. Returns AX coords — convert via `axRectToCocoa`.
func axReadFrame(_ element: AXUIElement) -> CGRect? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    // Safe: see `axReadSelectedRange` — `CFGetTypeID` is the guard.
    AXValueGetValue(v as! AXValue, .cgRect, &rect)
    return rect
}

/// Walk up an AX element's window chain to the containing window, then read
/// its on-screen frame. The window frame is the broadest fallback that's
/// still the right *region of the screen* (vs. pinning to a screen corner)
/// when neither caret bounds nor element frame are available.
func axReadContainingWindowFrame(_ element: AXUIElement) -> CGRect? {
    var windowRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
          let win = windowRef, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
    let windowElement: AXUIElement = win as! AXUIElement
    return axReadFrame(windowElement)
}

/// Caches the primary screen's height for `axRectToCocoa`. `NSScreen.screens`
/// walks the window-server display list on every access; `axRectToCocoa` runs
/// on the caret-tracking hot path, so the height is cached and only recomputed
/// when the display configuration actually changes.
@MainActor
private enum PrimaryScreen {
    private static var cachedHeight: CGFloat?
    private static var observing = false

    /// Height of the primary screen (the one with frame origin (0,0)), or 0
    /// if there is somehow no screen.
    static var height: CGFloat {
        if !observing {
            observing = true
            // Process-lifetime observer — never removed by design (the cache
            // lives as long as the app). Invalidates on monitor plug/unplug,
            // resolution change, arrangement change.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { cachedHeight = nil }
            }
        }
        if let h = cachedHeight { return h }
        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let h = screen?.frame.height ?? 0
        cachedHeight = h
        return h
    }
}

/// Convert an AX rect (top-left origin, primary-display coords) to a Cocoa screen rect
/// (bottom-left origin). Multi-monitor setups with displays above the primary need extra
/// work — handled in a later milestone.
@MainActor
func axRectToCocoa(_ axRect: CGRect) -> CGRect {
    let primaryHeight = PrimaryScreen.height
    guard primaryHeight > 0 else { return axRect }
    return CGRect(
        x: axRect.minX,
        y: primaryHeight - axRect.maxY,
        width: axRect.width,
        height: axRect.height
    )
}
