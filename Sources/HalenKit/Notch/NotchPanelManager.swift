import AppKit
import SwiftUI
import HalenPluginAPI

/// Host side of the notch surface: one borderless, non-activating,
/// always-on-top panel per screen at the top-center, rebuilt when screens
/// change, with a global click monitor for the "clicked outside" collapse
/// signal. Ported from NotchBar's `NotchPanelController`/`MultiScreenManager`
/// and generalized: the plugin supplies the per-screen SwiftUI content, the
/// host owns the windows.
///
/// Single-holder: the notch is a physical strip of pixels, so `acquire`
/// throws if another plugin already holds it.
@MainActor
package final class NotchPanelManager {
    @MainActor
    private final class PanelController {
        let panel: NSPanel

        init(screen: NSScreen, size: CGSize, content: AnyView) {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.maxY - size.height

            panel = KeyableNotchPanel(
                contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.level = .statusBar + 1
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isMovableByWindowBackground = false
            panel.hidesOnDeactivate = false

            let hosting = NSHostingView(rootView: content)
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.orderFrontRegardless()
        }

        func teardown() { panel.orderOut(nil) }
    }

    private var controllers: [CGDirectDisplayID: PanelController] = [:]
    private var ownerPluginId: String?
    private var contentProvider: (@MainActor (NotchScreenInfo) -> AnyView)?
    private var panelSize = CGSize(width: 420, height: 600)
    private var clickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private weak var activeHandle: Handle?

    package init() {}

    func acquire(pluginId: String,
                 panelSize: CGSize,
                 content: @escaping @MainActor (NotchScreenInfo) -> AnyView) throws -> NotchSurfaceHandle {
        if let ownerPluginId, ownerPluginId != pluginId {
            throw NotchSurfaceError.alreadyHeld(byPluginId: ownerPluginId)
        }
        releaseInternal()   // same plugin re-acquiring replaces its panels

        self.ownerPluginId = pluginId
        self.panelSize = panelSize
        self.contentProvider = content
        rebuildPanels()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildPanels() }
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let location = NSEvent.mouseLocation
                if !self.controllers.values.contains(where: { $0.panel.frame.contains(location) }) {
                    self.activeHandle?.onOutsideClick?()
                }
            }
        }

        let handle = Handle(manager: self)
        activeHandle = handle
        Log.info("NotchPanelManager: \(pluginId) acquired the notch surface (\(controllers.count) screen(s))")
        return handle
    }

    private func rebuildPanels() {
        guard let contentProvider else { return }
        for (_, controller) in controllers { controller.teardown() }
        controllers.removeAll()
        for screen in NSScreen.screens {
            let info = NotchScreenInfo(screenID: screen.notchDisplayID,
                                       hasNotch: screen.hasHardwareNotch,
                                       frame: screen.frame)
            controllers[screen.notchDisplayID] = PanelController(
                screen: screen, size: panelSize, content: contentProvider(info))
        }
    }

    private func releaseInternal() {
        for (_, controller) in controllers { controller.teardown() }
        controllers.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        contentProvider = nil
        activeHandle = nil
        ownerPluginId = nil
    }

    @MainActor
    private final class Handle: NotchSurfaceHandle {
        private weak var manager: NotchPanelManager?
        var onOutsideClick: (@MainActor () -> Void)?

        init(manager: NotchPanelManager) {
            self.manager = manager
        }

        func reloadContent() {
            manager?.rebuildPanels()
        }

        func release() {
            manager?.releaseInternal()
        }
    }
}

/// Per-plugin gate handed out through `PluginContext.notch`.
@MainActor
final class NotchSurfaceGate: NotchSurfaceService {
    private let manager: NotchPanelManager
    private let pluginId: String

    init(manager: NotchPanelManager, pluginId: String) {
        self.manager = manager
        self.pluginId = pluginId
    }

    func acquire(panelSize: CGSize,
                 content: @escaping @MainActor (NotchScreenInfo) -> AnyView) throws -> NotchSurfaceHandle {
        try manager.acquire(pluginId: pluginId, panelSize: panelSize, content: content)
    }
}

/// Borderless panels refuse key status by default; the notch surface hosts
/// text fields (session message input), so it must be able to become key.
final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    /// CoreGraphics display id backing this screen.
    var notchDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// True when the screen has a physical camera notch.
    var hasHardwareNotch: Bool {
        safeAreaInsets.top > 0
    }
}
