import AppKit
import Carbon.HIToolbox
import Foundation
import HalenPluginAPI
import SwiftUI

/// Notch Boss — the NotchBar app ported into Halen as a first-party plugin.
///
/// Everything NotchBar did lives on unchanged: the Unix-socket approval IPC
/// (`~/.notchbar/notchbar.sock`), the hook script and `~/.claude/settings.json`
/// integration, the Python MCP coordination server, Codex transcript
/// monitoring, the embedded SwiftTerm terminal, and the whole notch UI.
/// What moved to the host: window/panel lifecycle (the notch surface service),
/// global hotkeys (the hotkey service), onboarding + settings windows (the
/// plugin detail pane), and update checking (Sparkle).
@MainActor
public final class NotchBoss: HalenPlugin {
    public static let pluginManifest = PluginManifest(
        id: "com.halen.notch-boss", name: "Notch Boss",
        summary: "Your coding agents, live in the notch: approvals, diffs, costs, conflicts.",
        version: "0.4.0",
        events: [],
        capabilities: [.notchOverlay, .observeProcesses, .hotkeys, .notifications],
        icon: "sparkles.rectangle.stack", category: .agents)

    public var manifest: PluginManifest { Self.pluginManifest }

    private let context: PluginContext
    private var state: NotchState?
    private var providerManager: ProviderManager?
    private var surfaceHandle: NotchSurfaceHandle?

    public init(context: PluginContext) {
        self.context = context
    }

    public func start() {
        // One-shot import of NotchBar's settings. Must run before the
        // providers register: ProviderRegistry.register() seeds
        // `plugin.disabled.*` defaults for beta providers (Codex), and the
        // migrator only copies keys the destination hasn't set yet.
        NotchBarMigrator.migrateIfNeeded()

        // Register the bundled Matrix Sans Screen font (NotchBar did this in
        // its AppDelegate).
        FontManager.registerFonts()

        let state = NotchState()
        self.state = state

        // Crude-but-faithful: NotchBar's UI reaches its controllers through
        // ProviderManager.shared / ClaudeCodeBridge.shared /
        // CoordinationEngine.shared. The initializers set the shared
        // references; stop() clears them.
        let providerManager = ProviderManager(state: state)
        self.providerManager = providerManager
        providerManager.register(EmbeddedTerminalProvider(state: state))
        providerManager.register(ClaudeCodeBridge(state: state))
        providerManager.register(CodexProvider(state: state))
        providerManager.register(ConflictDetectorProvider(state: state))
        providerManager.start()

        // The notch windows come from the host now — one panel per screen,
        // geometry matching NotchBar's NotchPanelController (420×600).
        surfaceHandle = try? context.notch?.acquire(panelSize: CGSize(width: 420, height: 600)) { [state] info in
            AnyView(NotchView(state: state, screenID: info.screenID, hasNotch: info.hasNotch))
        }
        // NotchBar's MultiScreenManager global click monitor, host-provided.
        surfaceHandle?.onOutsideClick = { [weak state] in
            if state?.expandedScreenID != nil { state?.expandedScreenID = nil }
        }

        registerHotkeys(state: state)
    }

    public func stop() {
        // ProviderManager.cleanup() runs each provider's cleanup().
        // ClaudeCodeBridge.cleanup() auto-approves every pending response
        // before closing the socket, so no hook script is left hanging.
        providerManager?.cleanup()
        if ProviderManager.shared === providerManager {
            ProviderManager.shared = nil
        }
        ClaudeCodeBridge.shared = nil
        providerManager = nil

        surfaceHandle?.release()
        surfaceHandle = nil

        context.hotkeys?.unregisterAll()
        state = nil
    }

    public func makeDetailView() -> AnyView {
        AnyView(NotchBossDetailView())
    }

    // MARK: - Hotkeys
    // The same five Cmd+Shift chords NotchBar's Carbon HotkeyManager claimed,
    // with identical handler logic, routed through the host's hotkey service.

    private func registerHotkeys(state: NotchState) {
        guard let hotkeys = context.hotkeys else { return }
        let mods: NSEvent.ModifierFlags = [.command, .shift]

        hotkeys.register(id: "notchboss.toggle", keyCode: UInt32(kVK_ANSI_C), modifiers: mods) {
            Log.info("NotchBoss hotkey: Cmd+Shift+C (toggle)")
            if state.expandedScreenID != nil {
                state.expandedScreenID = nil
            } else {
                let loc = NSEvent.mouseLocation
                state.expandedScreenID = (NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main)?.displayID
            }
        }

        hotkeys.register(id: "notchboss.approve", keyCode: UInt32(kVK_ANSI_Y), modifiers: mods) {
            guard let session = state.activeSession, let approval = session.pendingApproval else { return }
            Log.info("NotchBoss hotkey: Cmd+Shift+Y (approve \(approval.requestId))")
            ProviderManager.shared?.approve(requestId: approval.requestId, session: session)
        }

        hotkeys.register(id: "notchboss.reject", keyCode: UInt32(kVK_ANSI_N), modifiers: mods) {
            guard let session = state.activeSession, let approval = session.pendingApproval else { return }
            Log.info("NotchBoss hotkey: Cmd+Shift+N (reject \(approval.requestId))")
            ProviderManager.shared?.reject(requestId: approval.requestId, session: session)
        }

        hotkeys.register(id: "notchboss.next", keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: mods) {
            guard state.sessions.count > 1 else { return }
            let next = (state.activeSessionIndex + 1) % state.sessions.count
            Log.info("NotchBoss hotkey: Cmd+Shift+] (next session \(next))")
            state.selectCard(next)
        }

        hotkeys.register(id: "notchboss.prev", keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: mods) {
            guard state.sessions.count > 1 else { return }
            let prev = (state.activeSessionIndex - 1 + state.sessions.count) % state.sessions.count
            Log.info("NotchBoss hotkey: Cmd+Shift+[ (prev session \(prev))")
            state.selectCard(prev)
        }
    }
}
