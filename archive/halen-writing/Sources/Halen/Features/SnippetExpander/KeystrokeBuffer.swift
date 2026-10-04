import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// A passive, app-agnostic record of the characters the user has typed
/// contiguously into the *currently focused* text field — reconstructed from
/// the global keystroke stream rather than read out of the field via the
/// Accessibility API.
///
/// This is what lets snippet expansion work in text boxes the AX tree can't
/// reach: web fields in Chromium browsers, Electron apps, and anywhere else
/// `kAXValueAttribute` comes back empty. We never ask the app what it
/// contains — we already know, because we watched it being typed. Write-back
/// then goes through `CaretObserver.pasteFallback`, which is itself
/// app-agnostic, so the whole path needs no AX support and no browser
/// extension.
///
/// The buffer is only a *best-effort mirror* of "text typed since the caret
/// was last known to be contiguous". Anything that could move the caret or
/// swap the field out from under us — a click, an arrow key, Return, an app
/// switch, a ⌘/⌃ shortcut — resets it. A stale buffer is therefore empty,
/// never wrong: callers get either an accurate tail or nothing.
///
/// Requires Input Monitoring (`NSEvent` global monitors). Halen already
/// requests it for the ⌃H and ⌃⌥R hotkeys; `IOHIDRequestAccess` is idempotent.
@MainActor
final class KeystrokeBuffer {
    /// Fired the instant the typed text ends with `;<word><separator>`.
    /// `token` is the `;word` part, `delimiter` the single separator
    /// character that closed it, and `precedingText` everything typed before
    /// `token` since the last reset (prior context for AI snippets).
    var onTrigger: ((_ token: String, _ delimiter: String, _ precedingText: String) -> Void)?

    /// Monotonic count of raw user-input events (key presses, mouse clicks,
    /// app switches) observed since launch. Callers snapshot this before an
    /// async operation and compare afterwards to tell "the user sat still"
    /// apart from "the user typed or clicked while we were busy". Synthesized
    /// events posted by Halen's own write-back are excluded — see `suppress`.
    private(set) var activityCount: Int = 0

    private var buffer: String = ""
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    /// Events arriving before this instant are ignored entirely. Set around
    /// Halen's own synthesized backspace/⌘V writes so the buffer doesn't
    /// mistake its own keystroke synthesis for the user typing.
    private var ignoreUntil: Date = .distantPast

    /// Drop the buffer once typing has been idle this long — a pragmatic
    /// guard against the buffer going stale across a long gap (the user
    /// stepped away, came back, and resumed typing without clicking first).
    private static let idleResetInterval: TimeInterval = 8
    private var lastKeyTime: Date = .distantPast

    /// Hard cap on retained characters: long enough to hold a typed paragraph
    /// for AI prior-context, bounded so a marathon typing run can't grow it
    /// without limit. Oldest characters drop off the front.
    private static let maxLength = 2048

    func start() {
        guard globalKeyMonitor == nil else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        // Global monitors only — they fire for *other* apps' events, never
        // Halen's own windows, which is exactly the scope we want: expand in
        // the apps the user works in, never inside Halen's settings fields.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // No logging here: this closure runs for every keystroke in every
            // app. Putting the user's text in a log would be a privacy leak.
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteUserAction() }
        }
        Log.info("KeystrokeBuffer: monitors installed (key=\(globalKeyMonitor != nil), mouse=\(globalMouseMonitor != nil))")
    }

    func stop() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        buffer.removeAll()
    }

    /// Clear the buffer without counting it as user activity. Used by the
    /// expander after it has rewritten the field.
    func reset() {
        buffer.removeAll()
    }

    /// Ignore every observed event for the next `millis` ms. Called immediately
    /// before Halen synthesizes a backspace/⌘V write so its own keystroke
    /// synthesis neither corrupts the buffer nor inflates `activityCount`.
    /// 250 ms comfortably covers HID-tap delivery latency.
    func suppress(forMillis millis: Int = 250) {
        ignoreUntil = Date().addingTimeInterval(Double(millis) / 1000)
    }

    /// Record an app switch: resets the buffer (the caret is now in a
    /// different app entirely) and counts as activity, so an AI write-back in
    /// flight knows the user has moved on.
    func noteAppSwitch() {
        activityCount &+= 1
        buffer.removeAll()
    }

    private func noteUserAction() {
        guard Date() >= ignoreUntil else { return }
        activityCount &+= 1
        buffer.removeAll()
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard Date() >= ignoreUntil else { return }

        // Secure input means a password field is focused; global monitors
        // normally go dark there, but if one slips through, never buffer it.
        if IsSecureEventInputEnabled() {
            buffer.removeAll()
            return
        }

        activityCount &+= 1

        // Idle too long — the buffer can no longer be trusted to sit right
        // before the caret. Start fresh from this keystroke.
        let now = Date()
        if now.timeIntervalSince(lastKeyTime) > Self.idleResetInterval {
            buffer.removeAll()
        }
        lastKeyTime = now

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘/⌃ chords are shortcuts or caret navigation, never literal text —
        // and we can't know where they leave the caret. Drop the buffer.
        // (Shift and Option stay: they're part of normal text entry.)
        if flags.contains(.command) || flags.contains(.control) {
            buffer.removeAll()
            return
        }

        switch Int(event.keyCode) {
        case kVK_Delete:                       // backspace — mirror it
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_ForwardDelete, kVK_Escape, kVK_Tab,
             kVK_Return, kVK_ANSI_KeypadEnter:
            // Caret moved, or the line/field changed — the buffer no longer
            // reflects the text immediately left of the caret.
            buffer.removeAll()
            return
        default:
            break
        }

        // A normal text-producing keystroke. `characters` honours the active
        // keyboard layout and dead keys (é, ñ, …); empty means a dead-key
        // press with nothing committed yet. A newline shouldn't reach here
        // (Return is handled above) but is filtered defensively.
        guard let typed = event.characters, !typed.isEmpty,
              !typed.contains(where: { $0.isNewline }) else {
            return
        }
        buffer.append(typed)
        if buffer.count > Self.maxLength {
            buffer.removeFirst(buffer.count - Self.maxLength)
        }

        // A trigger fires the instant a separator closes the `;word` token.
        if let last = typed.last, last.isWhitespace || last.isPunctuation {
            detectTrigger(closedBy: last)
        }
    }

    /// After a separator was typed, check whether the text just before it is
    /// a `;word` snippet trigger. `delimiter` is that separator.
    private func detectTrigger(closedBy delimiter: Character) {
        guard let match = parseKeystrokeTrigger(in: buffer, delimiter: delimiter) else { return }
        onTrigger?(match.token, String(delimiter), match.preceding)
    }
}

/// Pure trigger-parse for the keystroke buffer. Given the contiguously-typed
/// text so far (`typed`, which must end with `delimiter`), returns the `;word`
/// trigger token and the text preceding it — or `nil` when the tail isn't a
/// `;word<delimiter>` pattern. A "word" is letters and digits only; the `;`
/// sentinel must sit immediately before it.
///
/// Extracted as a free function (mirroring `wordRange`) so the detection
/// logic can be unit-tested without standing up NSEvent monitors.
func parseKeystrokeTrigger(in typed: String, delimiter: Character)
    -> (token: String, preceding: String)? {
    var chars = Array(typed)
    guard chars.last == delimiter else { return nil }
    chars.removeLast()                              // drop the delimiter

    // Walk back over the trigger word (letters / digits only).
    var i = chars.count
    while i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { i -= 1 }
    let wordStart = i
    guard wordStart < chars.count else { return nil }   // empty word — e.g. ";;"
    guard wordStart > 0, chars[wordStart - 1] == ";" else { return nil }  // no sentinel

    let token = ";" + String(chars[wordStart..<chars.count])
    let preceding = String(chars[0..<(wordStart - 1)])
    return (token, preceding)
}
