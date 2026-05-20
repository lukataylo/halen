import AppKit
import SwiftUI

/// Hosts the Plugin Store as a standalone window.
///
/// Deliberately *not* a `.sheet` on the menubar dropdown: a sheet is tied to
/// the dropdown popover's lifecycle and vanishes the moment the popover loses
/// focus — exactly when the user clicks "Install" and a download starts. A
/// real window survives, can be moved, and behaves the way a store should.
@MainActor
final class PluginStoreWindowController {
    private let registry: PluginRegistry
    private let model: PluginStoreModel
    private var window: NSWindow?

    init(registry: PluginRegistry, model: PluginStoreModel) {
        self.registry = registry
        self.model = model
    }

    /// Show the store window — created lazily on the first call, re-focused on
    /// every call after. `isReleasedWhenClosed = false` keeps the instance so
    /// a fetched registry / in-progress install survives a close-and-reopen.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Plugin Store"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 480, height: 420)
        w.contentView = NSHostingView(rootView: PluginStoreView(
            registry: registry,
            model: model,
            onClose: { [weak self] in self?.window?.close() }
        ))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        // Accessory (LSUIElement) apps don't get window focus for free —
        // activate explicitly so the store comes to the foreground.
        NSApp.activate(ignoringOtherApps: true)
    }
}
