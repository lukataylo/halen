import AppKit
import SwiftUI

/// Floats the `OnboardingFlow` in its own borderless, translucent window on
/// first launch — and any time the user re-triggers it from Settings.
///
/// Single-instance: `present(...)` brings the existing window to front if
/// it's already up. Reaching Done or hitting Skip flips
/// `halen.onboarding.completed = true` so first-run never repeats unless
/// the user explicitly asks for it (Settings → About → "Run setup again").
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// UserDefaults key for "have we walked this user through setup
    /// already?" Read at app launch; flipped when the flow finishes or the
    /// window is dismissed.
    static let completedKey = "halen.onboarding.completed"
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    private var window: NSWindow?
    private let registry: PluginRegistry

    init(registry: PluginRegistry) {
        self.registry = registry
    }

    /// Show the onboarding window. If already on-screen, refocuses.
    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingView(
            rootView: OnboardingFlow(registry: registry) { [weak self] in
                self?.finish()
            }
        )

        // Borderless, full-size-content, translucent window so the SwiftUI
        // `.ultraThinMaterial` background reads as glass over the desktop
        // / underlying apps. `.titled` is still in the mask so the window
        // gets a real shadow + screen anchor; the title-bar itself is
        // hidden by `titlebarAppearsTransparent` + `titleVisibility`.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Set up Halen"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.isOpaque = false                  // let the material show through
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isReleasedWhenClosed = false      // keep instance for re-trigger
        win.contentView = host
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    /// Re-trigger entry — called from Settings. Clears the completion
    /// flag and brings the window up. Idempotent: calling while the
    /// window is already on-screen just refocuses.
    func presentAgain() {
        UserDefaults.standard.set(false, forKey: Self.completedKey)
        present()
    }

    // MARK: - Lifecycle

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
        Log.info("Onboarding: completed")
    }

    /// Closing via the red close button counts as a Skip — flip the
    /// completed flag so we don't re-pop next launch. The user can still
    /// re-trigger from Settings.
    func windowWillClose(_ notification: Notification) {
        if !Self.isCompleted {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
    }
}
