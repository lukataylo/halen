import AppKit
import ApplicationServices

/// Bridges Halen's silent inline edits to VoiceOver.
///
/// Halen's entire job is to mutate text in the focused field via the
/// Accessibility API — typo fixes, snippet expansions, paragraph rewrites,
/// AI answers landed at the caret. VoiceOver users get **no signal** from
/// any of that: the OS doesn't announce AX-driven mutations because they
/// look identical to the app itself rewriting its own value. Without an
/// explicit announcement Halen is invisible to assistive tech.
///
/// `AnnounceCenter.say(_:)` posts an `NSAccessibility.Notification.announcementRequested`
/// on Halen's main window (or `NSApp` as a fallback when the menubar app has no
/// key window). VoiceOver picks the announcement up, queues it at the requested
/// priority, and speaks it — `.medium` waits for the current utterance to
/// finish so the user isn't interrupted mid-word, `.high` cuts through for
/// completion events the user is actively waiting on.
///
/// `@MainActor` because `NSAccessibility.post` must come from the main
/// thread; AppKit's accessibility plumbing isn't thread-safe.
@MainActor
enum AnnounceCenter {
    /// Speak `message` through VoiceOver if it is running. Silent no-op
    /// when VO is off — there's no listener to receive the notification
    /// and `NSAccessibility.post` short-circuits internally.
    ///
    /// Messages should be a single short clause. VoiceOver speaks the
    /// entire payload; a paragraph would block subsequent announcements
    /// for seconds and frustrate the user. "Fixed 'teh' to 'the'" good;
    /// "Halen has fixed your typo by replacing 'teh' with 'the' in your
    /// current document" bad.
    static func say(_ message: String,
                    priority: NSAccessibilityPriorityLevel = .medium) {
        guard !message.isEmpty else { return }

        // Prefer the app's key window when available — VoiceOver routes
        // announcements per-window, and a window-anchored post is what the
        // docs recommend. Halen is `LSUIElement` (menubar app) and very
        // often has no key window, in which case `NSApp` itself is a valid
        // `NSAccessibilityElement` and serves as a process-level fallback.
        let element: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any

        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }
}
