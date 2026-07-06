import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// Everything a plugin gets from the host, capability-gated at construction.
///
/// The host builds one context per plugin from its manifest: a service is
/// non-nil exactly when the plugin declared the matching capability *and*
/// the user hasn't revoked it in the permissions screen. Toggling a grant
/// restarts the plugin, so a service reference never goes stale mid-flight.
///
/// This is the entire API. If a plugin needs something that isn't here, the
/// answer is a host change, not a private import — plugin targets do not
/// link against HalenKit, so the compiler enforces that.
@MainActor
public struct PluginContext {
    /// The plugin's manifest id, e.g. `com.halen.writing-assistant`.
    public let pluginId: String

    /// Host event stream + plugin-sourced event publishing. Always present;
    /// which topics actually arrive is filtered by the manifest's `events`
    /// list and the observation capabilities.
    public let events: EventsService

    /// Shared on-device model access. Always present. Calls carry an
    /// `InferencePriority`; the host's scheduler guarantees a background
    /// plugin's queued work never delays a user-initiated call.
    public let inference: InferenceClient

    /// Scoped persistent storage. Always present.
    public let storage: StorageService

    /// System permission status/request broker. Always present — asking
    /// "do I have mic access?" is never privileged.
    public let permissions: PermissionService

    // ── Capability-gated (nil when undeclared or revoked) ──────────────
    /// `.observeText` and/or `.insertText`. Reading members is observe;
    /// the mutating members require `.insertText` and no-op without it.
    public let text: TextService?
    /// `.popoverUI` (prompt/panels) — toasts additionally need `.notifications`.
    public let ui: UIService?
    /// `.hotkeys`
    public let hotkeys: HotkeyService?
    /// `.clipboard`
    public let clipboard: ClipboardService?
    /// `.speak`
    public let speech: SpeechService?
    /// `.runShortcuts`
    public let shortcuts: ShortcutsService?
    /// `.observeScreen`
    public let screen: ScreenService?
    /// `.notchOverlay`
    public let notch: NotchSurfaceService?
    /// `.toneProfiles` — the shared per-app tone store + recently focused apps.
    public let toneProfiles: AppToneProfileStore?
    public let recentApps: RecentAppsModel?
    /// `.snippets` — the host-owned snippet library.
    public let snippets: SnippetStore?

    public init(pluginId: String,
                events: EventsService,
                inference: InferenceClient,
                storage: StorageService,
                permissions: PermissionService,
                text: TextService? = nil,
                ui: UIService? = nil,
                hotkeys: HotkeyService? = nil,
                clipboard: ClipboardService? = nil,
                speech: SpeechService? = nil,
                shortcuts: ShortcutsService? = nil,
                screen: ScreenService? = nil,
                notch: NotchSurfaceService? = nil,
                toneProfiles: AppToneProfileStore? = nil,
                recentApps: RecentAppsModel? = nil,
                snippets: SnippetStore? = nil) {
        self.pluginId = pluginId
        self.events = events
        self.inference = inference
        self.storage = storage
        self.permissions = permissions
        self.text = text
        self.ui = ui
        self.hotkeys = hotkeys
        self.clipboard = clipboard
        self.speech = speech
        self.shortcuts = shortcuts
        self.screen = screen
        self.notch = notch
        self.toneProfiles = toneProfiles
        self.recentApps = recentApps
        self.snippets = snippets
    }
}

// MARK: - Events

/// Subscribe to host events / publish plugin-sourced ones. The host filters
/// the subscription to the topics the manifest declared, so a plugin that
/// never asked for `text.pause` never sees your text.
public protocol EventsService: AnyObject, Sendable {
    /// One stream per call; terminate it (break the loop / cancel the task)
    /// to unsubscribe. Slow consumers drop oldest events rather than
    /// backpressuring the host.
    func subscribe() -> AsyncStream<Event>
    /// Publish a plugin-sourced event (`inference.activity`, `finding.*`).
    /// Host-sourced topics (`text.pause`, `app.focused`, `caret.moved`)
    /// are silently dropped — only the host observes the system.
    func publish(_ event: Event)
}

// MARK: - Text

/// Read and mutate the focused text field. The focused element is exposed as
/// a raw `AXUIElement` on purpose — plugins combine it with the `axRead*`
/// free functions in this module for bounds/selection reads. Deliberately
/// crude: a typed wrapper can come the day a third-party plugin needs one.
@MainActor
public protocol TextService: AnyObject {
    /// The element that currently has keyboard focus, if the host is
    /// tracking one. Capture it before showing UI that steals focus.
    var focusedElement: AXUIElement? { get }

    /// Replace `range` in the focused element. Falls back to clipboard-paste
    /// and synthesized keystrokes for AX-hostile apps. `describedAs` is
    /// spoken by VoiceOver. Requires `.insertText`; returns false without it.
    @discardableResult
    func replaceRange(_ range: NSRange, with replacement: String, describedAs description: String?) -> Bool

    /// Same, targeting an explicitly captured element (for async work that
    /// must land in the field it started from).
    @discardableResult
    func replaceRange(_ range: NSRange, with replacement: String, in element: AXUIElement, describedAs description: String?) -> Bool

    /// Last-ditch write path: synthesize `deleteCount` backspaces then paste
    /// `text`, preserving the user's clipboard. Requires `.insertText`.
    @discardableResult
    func pasteFallback(text: String, deleteCount: Int) -> Bool

    /// Live caret bounds of the focused element in screen coordinates
    /// (top-left origin), if readable right now.
    func caretBounds() -> CGRect?
}

// MARK: - UI

/// Popovers, prompts, notifications. All rendering happens in the host
/// process; this is about *who is allowed to interrupt the user*.
@MainActor
public protocol UIService: AnyObject {
    /// Post a system notification. Requires `.notifications`.
    func toast(title: String, body: String)
    /// Blocking question: floats a panel with `actions` buttons, returns the
    /// chosen label, or nil on dismiss/timeout. Requires `.popoverUI`.
    func prompt(title: String, body: String, actions: [String], timeoutSeconds: Double?) async -> String?
}

// MARK: - Hotkeys

/// Global hotkeys, routed through the host's conflict registry so two
/// plugins claiming the same chord is surfaced in Settings instead of
/// silently misfiring.
@MainActor
public protocol HotkeyService: AnyObject {
    /// Register a chord. `id` is plugin-chosen and echoed nowhere — it just
    /// names the registration for `unregister`. Returns false if the chord
    /// is refused (conflict, or the OS declined).
    @discardableResult
    func register(id: String, keyCode: UInt32, modifiers: NSEvent.ModifierFlags,
                  onFire: @escaping @MainActor () -> Void) -> Bool
    func unregister(id: String)
    /// Unregister everything this plugin registered. Call from `stop()`.
    func unregisterAll()
}

// MARK: - Storage

/// Per-plugin persistence, scoped to
/// `~/Library/Application Support/Halen/<pluginId>/`.
public protocol StorageService: AnyObject, Sendable {
    /// The plugin's private directory (created on first access).
    var directory: URL { get }
    /// Read a JSON document from `directory`. nil if absent or unreadable.
    func readJSON<T: Decodable>(_ type: T.Type, from filename: String) -> T?
    /// Atomically write a JSON document into `directory`.
    func writeJSON<T: Encodable>(_ value: T, to filename: String)
}

// MARK: - Permissions

/// Query and request the *system* permissions behind capabilities. The host
/// owns every TCC prompt; plugins never call TCC APIs directly.
@MainActor
public protocol PermissionService: AnyObject {
    func status(of permission: SystemPermission) -> PermissionGrant
    /// Triggers the system prompt when possible. Returns the resulting grant.
    func request(_ permission: SystemPermission) async -> Bool
    func openSystemSettings(for permission: SystemPermission)
}

// MARK: - Clipboard

@MainActor
public protocol ClipboardService: AnyObject {
    func readString() -> String?
    func write(_ string: String)
}

// MARK: - Speech

@MainActor
public protocol SpeechService: AnyObject {
    /// Speak through the system voice. Interrupts any previous utterance
    /// from the same plugin.
    func speak(_ text: String)
    func stopSpeaking()
}

// MARK: - Shortcuts

/// Run a user-installed Shortcuts.app shortcut by name.
public protocol ShortcutsService: AnyObject, Sendable {
    /// Runs `shortcuts run <name>` with optional stdin `input`; returns
    /// stdout. Throws if the shortcut fails or doesn't exist.
    func run(name: String, input: String?) async throws -> String
}

// MARK: - Screen

/// Screen contents, behind an explicit grant. Requires the system Screen
/// Recording permission on top of the capability.
@MainActor
public protocol ScreenService: AnyObject {
    /// Capture the main display. Throws if Screen Recording is not granted.
    func captureMainDisplay() async throws -> CGImage
}
