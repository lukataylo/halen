import AppKit
import ApplicationServices

/// Observes the user's currently focused text field and emits events on the bus:
///   - `app.focused` when the frontmost app changes
///   - `caret.moved` when the caret or selection changes (with screen-space rect)
///   - `text.pause` (debounced ~600ms) when typing stops or focus changes
///
/// Implementation notes:
///   - One `AXObserver` per frontmost app. Swap on `NSWorkspace.didActivateApplication`.
///   - `kAXFocusedUIElementChangedNotification` is registered against the app element;
///     `kAXSelectedTextChangedNotification` and `kAXValueChangedNotification` are
///     registered against the currently focused element (re-bound on focus change).
///   - C callback is dispatched on the main run loop; we use `MainActor.assumeIsolated`
///     to hop back into actor-isolated code without an async detour.
@MainActor
final class CaretObserver {
    private let eventBus: EventBus
    private var workspaceToken: NSObjectProtocol?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var observedApp: NSRunningApplication?

    private var debounceTask: Task<Void, Never>?

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    deinit {
        // The AX C-callback (`axCallback`) holds an *unretained* pointer back to
        // us. If this object is deallocated without `stop()` having run, a
        // queued notification could still fire into freed memory. Tear the
        // run-loop source down here as a safety net — CF teardown isn't
        // actor-isolated, and removing a source from the main run loop is
        // thread-safe regardless of which thread `deinit` runs on.
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }

    func start() {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.switchToApp(app)
            }
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            switchToApp(frontmost)
        }
    }

    func stop() {
        debounceTask?.cancel()
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceToken = nil
        }
        tearDownObserver()
    }

    /// The element currently focused. Callers can capture this and pass it back
    /// to `replaceRange(_:with:in:)` later, so an async write (e.g. a Gemma
    /// response that arrives after the user alt-tabbed away) still lands in the
    /// field it was started from rather than whatever happens to be focused now.
    var currentElement: AXUIElement? { focusedElement }

    /// Replace `range` (UTF-16 units) in the currently focused element with `replacement`.
    @discardableResult
    func replaceRange(_ range: NSRange, with replacement: String) -> Bool {
        guard let element = focusedElement else { return false }
        return replaceRange(range, with: replacement, in: element)
    }

    /// Replace `range` (UTF-16 units) in a specific `element` with `replacement`.
    /// Uses the AX "set selection then set selected-text" pattern, which most native AppKit
    /// text fields honor. Returns false for apps that don't support AX writes
    /// (most Electron / web text fields, terminals) or if the element has gone stale.
    @discardableResult
    func replaceRange(_ range: NSRange, with replacement: String, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue: AXValue = withUnsafePointer(to: &cfRange, { ptr in
            AXValueCreate(.cfRange, UnsafeRawPointer(ptr))
        }) else { return false }

        let setRange = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard setRange == .success else {
            Log.warn("replaceRange: failed to set selection range, status=\(setRange.rawValue)")
            return false
        }

        let setText = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )
        guard setText == .success else {
            Log.warn("replaceRange: failed to write replacement, status=\(setText.rawValue)")
            return false
        }
        return true
    }

    // MARK: - App / observer lifecycle

    private func switchToApp(_ app: NSRunningApplication) {
        // Skip self — observing our own menubar app is noise.
        if app.bundleIdentifier == "com.dadiani.halen" { return }

        tearDownObserver()
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &newObserver)
        guard result == .success, let observer = newObserver else {
            Log.warn("AXObserverCreate failed for \(app.localizedName ?? "pid:\(pid)") status=\(result.rawValue)")
            return
        }

        // Attach the run-loop source *before* registering notifications so the
        // observer is live to deliver them the moment they fire.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appResult = AXObserverAddNotification(
            observer, appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon
        )
        if appResult != .success {
            Log.debug("AXObserverAddNotification(focused-ui-changed) status=\(appResult.rawValue) for \(app.localizedName ?? "?")")
        }

        self.observer = observer
        self.appElement = appElement
        self.observedApp = app

        Log.info("AX observing app: \(app.localizedName ?? "pid:\(pid)") (\(app.bundleIdentifier ?? "no-bid"))")

        eventBus.publish(.appFocused(.init(
            appBundleId: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "",
            timestamp: Date()
        )))

        attachToFocusedElement()
    }

    private func tearDownObserver() {
        debounceTask?.cancel()
        debounceTask = nil

        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        appElement = nil
        focusedElement = nil
        observedApp = nil
    }

    private func attachToFocusedElement() {
        guard let observer, let appElement else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let previous = focusedElement {
            AXObserverRemoveNotification(observer, previous, kAXSelectedTextChangedNotification as CFString)
            AXObserverRemoveNotification(observer, previous, kAXValueChangedNotification as CFString)
        }

        guard let element = axReadFocusedElement(appElement) else {
            focusedElement = nil
            return
        }

        _ = AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        focusedElement = element

        emitCaretMoved(element: element)
        emitTextSnapshot(reason: "focus")
        // The element's AX value often lags the document actually loading — e.g.
        // opening a note in TextEdit, where the focus snapshot reads "" before the
        // content lands in the AX tree. Re-snapshot shortly after so text-driven
        // plugins (SentimentGuard, BurnoutCopilot) see the real content without
        // waiting for the user's first keystroke.
        scheduleDebouncedEmit(reason: "focus-settle")
    }

    // MARK: - Notification handling

    fileprivate func handleNotification(element: AXUIElement, name: String) {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            attachToFocusedElement()
        case kAXSelectedTextChangedNotification:
            emitCaretMoved(element: element)
            scheduleDebouncedEmit(reason: "selection")
        case kAXValueChangedNotification:
            scheduleDebouncedEmit(reason: "value")
        default:
            break
        }
    }

    /// `text.pause` debounce. 600ms keeps snippet expansion and typo learning
    /// responsive while noticeably cutting per-keystroke AX reads and fan-out
    /// versus the old 400ms. Inference-driven plugins debounce *further* on top
    /// of this (see SentimentGuard / BurnoutCopilot) so Gemma isn't run mid-type.
    private static let pauseDebounce: Duration = .milliseconds(600)

    private func scheduleDebouncedEmit(reason: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pauseDebounce)
            guard let self, !Task.isCancelled else { return }
            self.emitTextSnapshot(reason: "pause:\(reason)")
        }
    }

    private func emitTextSnapshot(reason: String) {
        guard let element = focusedElement, let app = observedApp else { return }
        let fullText = axReadString(element, kAXValueAttribute) ?? ""
        let fullOffset = axReadSelectedRange(element)?.location ?? 0

        // Cap payloads at 8k chars (windowed around the caret) so subscribers
        // — especially Gemma-backed plugins — don't get blasted with terminal
        // scrollback. For small inputs (typical email/Slack/Notes), this is
        // a no-op.
        let (text, caretOffset) = windowAroundCaret(text: fullText, offset: fullOffset, radius: 4000)

        eventBus.publish(.textPaused(.init(
            appBundleId: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "",
            text: text,
            caretOffset: caretOffset,
            timestamp: Date()
        )))
        Log.debug("text.pause reason=\(reason) app=\(app.localizedName ?? "?") fullChars=\(fullText.count) sent=\(text.count) offset=\(caretOffset)")
    }

    private func emitCaretMoved(element: AXUIElement) {
        guard let app = observedApp,
              let axRect = axReadCaretBounds(element) else { return }
        let cocoa = axRectToCocoa(axRect)
        eventBus.publish(.caretMoved(.init(
            appBundleId: app.bundleIdentifier ?? "",
            rect: .init(x: cocoa.minX, y: cocoa.minY, width: cocoa.width, height: cocoa.height),
            timestamp: Date()
        )))
    }
}

// MARK: - C callback bridge

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let observer = Unmanaged<CaretObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        observer.handleNotification(element: element, name: name)
    }
}
