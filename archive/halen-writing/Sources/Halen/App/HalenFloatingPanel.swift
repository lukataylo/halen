import AppKit

/// Factory for the borderless floating panels Halen overlays on other apps:
/// the caret indicator, the Sentiment Guard popover, the Voice Dictation
/// listening pill.
///
/// Four call sites used to hand-build these with `NSPanel(...)` + a dozen
/// property assignments, and the configs had already drifted —
/// `.fullScreenAuxiliary` was in three of four collection-behaviour sets,
/// `.ignoresCycle` in one, `hidesOnDeactivate` set explicitly in one. This
/// factory is the single definition; the per-site differences that *matter*
/// (level, shadow, whether it takes clicks) are explicit parameters,
/// everything else is uniform and correct.
enum HalenFloatingPanel {

    /// Build a configured borderless floating panel. The caller still owns
    /// `contentView` and positioning (`setFrame`/`orderFront…`).
    ///
    /// - size: the panel's content size.
    /// - level: `.statusBar` for always-on chrome (caret indicator, voice
    ///   pill), `.floating` for transient popovers.
    /// - interactive: `true` if the panel hosts controls the user clicks
    ///   (popover buttons); `false` for pure decoration, which then ignores
    ///   mouse events so clicks pass through to the app underneath.
    /// - shadow: drop shadow. Off for the tiny caret indicator (a shadow
    ///   under a 16 pt mark just smudges it), on for popovers.
    @MainActor
    static func make(size: NSSize,
                     level: NSWindow.Level,
                     interactive: Bool,
                     shadow: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.isMovable = false
        panel.ignoresMouseEvents = !interactive
        // These panels overlay *other* apps — they must stay put when Halen
        // itself isn't the active app, never join Cmd-` window cycling, ride
        // along to every Space, and survive another app going full-screen.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}
