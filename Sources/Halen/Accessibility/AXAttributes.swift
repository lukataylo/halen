import AppKit
import ApplicationServices

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

/// Convert an AX rect (top-left origin, primary-display coords) to a Cocoa screen rect
/// (bottom-left origin). Multi-monitor setups with displays above the primary need extra
/// work — handled in a later milestone.
func axRectToCocoa(_ axRect: CGRect) -> CGRect {
    guard let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
        return axRect
    }
    return CGRect(
        x: axRect.minX,
        y: main.frame.height - axRect.maxY,
        width: axRect.width,
        height: axRect.height
    )
}
