import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
    /// Separate, much shorter debounce for `caret.moved`. See `scheduleCaretMoved`.
    private var caretMovedTask: Task<Void, Never>?

    /// Short-lived retry loop for the "app focused, no text element yet" case.
    /// macOS doesn't reliably fire `kAXFocusedUIElementChangedNotification`
    /// for WebKit-hosted text editors (Notes' main editor, Messages compose,
    /// some Electron apps), so the initial attach finds the app shell and
    /// then misses the user clicking into the textbox. We retry a few times
    /// at increasing intervals; any successful attach cancels the remainder.
    /// Cancelled on app-switch or teardown so we never leak the closure.
    private var focusRetryTask: Task<Void, Never>?

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
        caretMovedTask?.cancel()
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
    ///
    /// `describedAs` is a short, human-readable summary of *what changed*
    /// that, on a successful write, gets posted to VoiceOver via
    /// `AnnounceCenter`. Pass nil when the caller is going to post its own
    /// announcement (e.g. AskHalen's "Answer inserted at cursor") to avoid
    /// double-speak; pass a brief clause like "Fixed 'teh' to 'the'" or
    /// "Expanded ;sig" otherwise. See `AnnounceCenter` for the rationale —
    /// VoiceOver users get no signal from a silent AX mutation otherwise.
    @discardableResult
    func replaceRange(_ range: NSRange,
                      with replacement: String,
                      describedAs description: String? = nil) -> Bool {
        guard let element = focusedElement else { return false }
        return replaceRange(range, with: replacement, in: element, describedAs: description)
    }

    /// Replace `range` (UTF-16 units) in a specific `element` with `replacement`.
    /// Uses the AX "set selection then set selected-text" pattern, which most
    /// native AppKit text fields honor. When AX writes are silently refused
    /// (the common case in Electron, web text fields, terminals) falls back to
    /// a clipboard-and-⌘V paste so the feature still works there — same
    /// observable result, less ideal mechanism.
    ///
    /// `describedAs` mirrors the focused-element overload: on success, post
    /// a VoiceOver announcement summarising the edit so assistive-tech users
    /// hear that something changed at their cursor. nil = don't announce
    /// (the caller will post its own).
    @discardableResult
    func replaceRange(_ range: NSRange,
                      with replacement: String,
                      in element: AXUIElement,
                      describedAs description: String? = nil) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue: AXValue = withUnsafePointer(to: &cfRange, { ptr in
            AXValueCreate(.cfRange, UnsafeRawPointer(ptr))
        }) else { return false }

        let setRange = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )

        // Path A — AX selection succeeded. Try the AX text write; if *that*
        // fails (Electron is the typical offender) the selection is already
        // set in the target field, so pasting with no preceding backspaces
        // replaces the AX-selected range cleanly.
        if setRange == .success {
            let setText = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                replacement as CFString
            )
            if setText == .success {
                if let description, !description.isEmpty {
                    AnnounceCenter.say(description)
                }
                return true
            }
            Log.info("replaceRange: AX write failed (status=\(setText.rawValue)) — pasting over AX-set selection")
            let ok = Self.pasteFallback(text: replacement, deleteCount: 0)
            if ok, let description, !description.isEmpty {
                AnnounceCenter.say(description)
            }
            return ok
        }

        // Path B — AX can't even set the selection (some web text fields).
        // Best effort: backspace `range.length` UTF-16 units to remove the
        // trigger token, then paste. Imperfect for grapheme-cluster boundaries
        // but right for ASCII trigger/correction text, which is the common case.
        Log.info("replaceRange: AX setRange failed (status=\(setRange.rawValue)) — backspace+paste fallback")
        let ok = Self.pasteFallback(text: replacement, deleteCount: range.length)
        if ok, let description, !description.isEmpty {
            AnnounceCenter.say(description)
        }
        return ok
    }

    /// Clipboard-and-⌘V fallback for apps that refuse AX writes. Saves and
    /// restores the user's clipboard around the paste so they don't lose what
    /// was on it. `deleteCount` synthesises that many backspace presses first
    /// — used to remove a snippet trigger or typo when AX couldn't select it.
    ///
    /// `nonisolated static` so plugin write paths can call it without an
    /// `await` hop. Keystroke synthesis already requires the Accessibility
    /// permission Halen has at launch.
    @discardableResult
    nonisolated static func pasteFallback(text: String, deleteCount: Int) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = savedPasteboardItems(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let safeDeletes = max(0, min(deleteCount, 256))   // safety cap
        for _ in 0..<safeDeletes {
            synthesizeKey(virtualKey: CGKeyCode(kVK_Delete), flags: [])
        }
        synthesizeKey(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Wait long enough for the target app to grab the string off the
        // pasteboard before we swap it back. 300 ms is the empirically-safe
        // value across Slack/Discord/VS Code/Chrome; faster occasionally
        // lands the user's old clipboard back into the field on slow renderers.
        // Wrap in @unchecked Sendable — NSPasteboard / NSPasteboardItem are
        // AppKit main-thread types, and the asyncAfter block also lands on
        // main, so the cross-actor warning is spurious.
        let restore = PasteboardRestore(pasteboard: pasteboard, items: saved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            restore.apply()
        }
        return true
    }

    /// Restore handle for the pasteFallback's deferred clipboard re-write.
    /// `@unchecked Sendable` so we can pass it into the `DispatchQueue.main`
    /// closure — both creation and execution happen on the main thread, so the
    /// "captured non-Sendable" warning is a false positive in this context.
    private struct PasteboardRestore: @unchecked Sendable {
        let pasteboard: NSPasteboard
        let items: [NSPasteboardItem]

        func apply() {
            guard !items.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
    }

    /// Synthesise one keyboard event pair (down + up) and post it at the HID
    /// layer so the focused app sees a real key press. Requires the
    /// Accessibility permission, which Halen already holds.
    private nonisolated static func synthesizeKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Snapshot the pasteboard's current contents across all data types so we
    /// can put it back after the paste. Best effort — apps that write
    /// custom non-data types lose those representations on restore.
    private nonisolated static func savedPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let originals = pasteboard.pasteboardItems else { return [] }
        return originals.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    // MARK: - App / observer lifecycle

    private func switchToApp(_ app: NSRunningApplication) {
        // Skip self — observing our own menubar app is noise.
        if app.bundleIdentifier == "com.dadiani.halen" { return }

        // App-focus tracking is independent of AX. Publish `.appFocused`
        // FIRST so Tone Profiles' "Recently used apps", per-app cooldowns,
        // and any future per-app feature get the signal even when AX is
        // denied / Halen hasn't been granted Accessibility yet. The AX
        // observer setup below is the more granular caret-tracking work
        // that legitimately needs the permission.
        eventBus.publish(.appFocused(.init(
            appBundleId: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "",
            timestamp: Date()
        )))

        tearDownObserver()
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        // Bound every subsequent AX read against this app to the hard ceiling
        // (see `axMessagingTimeoutSeconds`). Children inherit from the app, so
        // one call here covers the focused element + its windows. Frozen apps
        // will time out fast instead of wedging the main thread.
        axApplyMessagingTimeout(to: appElement)

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

        attachToFocusedElement()
    }

    private func tearDownObserver() {
        debounceTask?.cancel()
        debounceTask = nil
        focusRetryTask?.cancel()
        focusRetryTask = nil

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
            // Silent before — but the user can't tell whether the AX subscription
            // worked or not in this state, and "indicator is gone" is the symptom.
            // Now we log the gap, which is almost always "user has the app window
            // up but their text cursor isn't in any editable field" (notes list,
            // toolbar focused, no document open, etc.).
            Log.info("attachToFocusedElement: no focused element on \(observedApp?.localizedName ?? "?") — scheduling retries")
            scheduleFocusRetries()
            return
        }

        // We have a focused element — cancel any retry burst from a prior
        // empty attach so we don't keep polling against a working subscription.
        focusRetryTask?.cancel()
        focusRetryTask = nil

        _ = AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        focusedElement = element

        // On focus change emit the caret position immediately (no debounce —
        // a focus switch is a single discrete event, not a keystroke burst).
        emitCaretMoved()
        emitTextSnapshot(reason: "focus")
        // The element's AX value often lags the document actually loading — e.g.
        // opening a note in TextEdit, where the focus snapshot reads "" before the
        // content lands in the AX tree. Re-snapshot shortly after so text-driven
        // plugins (SentimentGuard, BurnoutCopilot) see the real content without
        // waiting for the user's first keystroke.
        scheduleDebouncedEmit(reason: "focus-settle")
    }

    /// Backup loop for apps that don't fire `kAXFocusedUIElementChangedNotification`
    /// when the user clicks into a WebKit-hosted text editor (Notes, Messages
    /// compose, some Electron). Re-probes the focused element at 300 ms,
    /// 800 ms, and 1600 ms — covers the common "click into the textbox right
    /// after the app activates" window without busy-looping.
    ///
    /// We do the probe inline (not via `attachToFocusedElement`) so the
    /// retry loop never re-enters the `scheduleFocusRetries` call site and
    /// can't fan out into overlapping tasks. The real attach work is
    /// duplicated as a single hop at the end; the retry loop's job is
    /// purely to discover the element.
    private func scheduleFocusRetries() {
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self] in
            for delayMs in [300, 800, 1600] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                // A real `kAXFocusedUIElementChangedNotification` may have
                // landed and run attach already — stop polling in that case.
                if self.focusedElement != nil { return }
                guard let appElement = self.appElement,
                      let element = axReadFocusedElement(appElement) else {
                    continue
                }
                // Found it. Wire the notifications and let attach do its
                // emit / snapshot bookkeeping. No reschedule risk: we have
                // a focused element, so attach's guard takes the success path.
                Log.info("attachToFocusedElement: retry succeeded after \(delayMs) ms on \(self.observedApp?.localizedName ?? "?")")
                _ = element  // silence unused if attach changes
                self.attachToFocusedElement()
                return
            }
        }
    }

    // MARK: - Notification handling

    fileprivate func handleNotification(element: AXUIElement, name: String) {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            attachToFocusedElement()
        case kAXSelectedTextChangedNotification:
            scheduleCaretMoved()
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

    /// `caret.moved` debounce. `kAXSelectedTextChangedNotification` fires once
    /// per keystroke; emitting on each one means a synchronous parameterized
    /// AX bounds round-trip (`axReadCaretBounds`) plus a full event-bus
    /// fan-out per character. 40 ms coalesces a fast typist's keystrokes into
    /// one emit without the overlay indicator visibly lagging the caret.
    private static let caretMovedDebounce: Duration = .milliseconds(40)

    private func scheduleCaretMoved() {
        caretMovedTask?.cancel()
        caretMovedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.caretMovedDebounce)
            guard let self, !Task.isCancelled else { return }
            self.emitCaretMoved()
        }
    }

    /// Reads the *current* focused element rather than a captured one — over
    /// the 40 ms debounce focus could have changed, and `attachToFocusedElement`
    /// keeps `focusedElement` current.
    private func emitCaretMoved() {
        guard let app = observedApp, let element = focusedElement else { return }
        guard let axRect = axReadCaretBounds(element) else {
            // Diagnostic: surfaces apps whose AX tree refuses to expose
            // caret bounds (rich-text views like Notes' WebKit pane often
            // do) so the overlay-indicator silence has a paper trail in
            // the log instead of being invisible.
            Log.info("caret.moved skipped — no AX bounds for \(app.localizedName ?? "?")")
            return
        }
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
