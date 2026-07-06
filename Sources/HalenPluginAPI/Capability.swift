import Foundation

/// Everything a plugin may observe or do, one case per grant. A plugin
/// declares the capabilities it needs in its `PluginManifest`; the host
/// surfaces that list in the permissions screen and hands the plugin a
/// `PluginContext` whose services are nil for anything undeclared or revoked.
///
/// The raw values are the wire strings used in `halen-plugin.json` manifests
/// (external plugins) and are covenant: never change one after shipping.
public enum Capability: String, Codable, CaseIterable, Sendable, Identifiable {
    // ── Observe ─────────────────────────────────────────────────────
    /// Text events (`text.pause`, `caret.moved`), the focused element, and
    /// reads of the selection around the caret.
    case observeText = "observe-text"
    /// `app.focused` events — which app is frontmost, and when it changes.
    case observeApps = "observe-apps"
    /// Raw keystroke reconstruction via global event monitors (for fields
    /// the accessibility API can't read, e.g. Chromium). Requires the
    /// system Input Monitoring permission on top of this grant.
    case observeKeystrokes = "observe-keystrokes"
    /// Screen contents. The heaviest observation there is; also requires
    /// the system Screen Recording permission.
    case observeScreen = "observe-screen"
    /// Local process observation: watching agent CLIs, tailing their
    /// transcripts, serving local IPC sockets for their hooks. This is
    /// Notch Boss's world — nothing here touches the network.
    case observeProcesses = "process-observation"

    // ── Act ─────────────────────────────────────────────────────────
    /// Insert or replace text in the focused field (AX write, with
    /// clipboard-paste fallback).
    case insertText = "insert-text"
    /// Show popovers / floating panels / interactive prompts.
    case popoverUI = "popover-ui"
    /// Post system notifications.
    case notifications = "notifications"
    /// Speak text aloud through the system voice.
    case speak = "speak"
    /// Run a named Shortcuts.app shortcut.
    case runShortcuts = "run-shortcuts"
    /// Register global hotkeys (routed through the host's conflict registry).
    case hotkeys = "hotkeys"
    /// Read from and write to the system clipboard.
    case clipboard = "clipboard"
    /// Record from the microphone. Also requires the system mic permission.
    case microphone = "microphone"
    /// On-device speech recognition. Also requires the system permission.
    case speechRecognition = "speech-recognition"
    /// Read and create calendar events (host-brokered EventKit).
    case calendar = "calendar"
    /// Run AppleScript against other apps (e.g. closing a browser tab).
    /// Also requires the system Automation permission per target app.
    case automation = "automation"
    /// Render content in the notch surface — the always-on-top panel at the
    /// top-center of every screen.
    case notchOverlay = "notch-overlay"

    // ── Shared host data ────────────────────────────────────────────
    /// Read/write the per-app tone profiles shared across writing plugins.
    case toneProfiles = "tone-profiles"
    /// Read/write the host-owned snippet library.
    case snippets = "snippets"

    public var id: String { rawValue }

    /// Human-readable name for the permissions screen.
    public var displayName: String {
        switch self {
        case .observeText:        return "Observe your text"
        case .observeApps:        return "See the frontmost app"
        case .observeKeystrokes:  return "Observe keystrokes"
        case .observeScreen:      return "See screen contents"
        case .observeProcesses:   return "Observe local processes"
        case .insertText:         return "Insert text"
        case .popoverUI:          return "Show popovers"
        case .notifications:      return "Post notifications"
        case .speak:              return "Speak aloud"
        case .runShortcuts:       return "Run Shortcuts"
        case .hotkeys:            return "Register hotkeys"
        case .clipboard:          return "Use the clipboard"
        case .microphone:         return "Use the microphone"
        case .speechRecognition:  return "Recognize speech"
        case .calendar:           return "Access your calendar"
        case .automation:         return "Control other apps"
        case .notchOverlay:       return "Draw in the notch"
        case .toneProfiles:       return "Shared tone profiles"
        case .snippets:           return "Shared snippet library"
        }
    }

    /// One-line explanation of what granting this actually exposes,
    /// shown under the toggle in the permissions screen.
    public var explanation: String {
        switch self {
        case .observeText:        return "Receives the paragraph around your caret when you pause typing."
        case .observeApps:        return "Told the bundle id and name of the app you switch to."
        case .observeKeystrokes:  return "Reconstructs typed characters in fields accessibility can't read."
        case .observeScreen:      return "Can capture what's on screen. Requires Screen Recording."
        case .observeProcesses:   return "Watches local agent processes and reads their transcripts on disk."
        case .insertText:         return "Can type into the focused field on your behalf."
        case .popoverUI:          return "Can float panels and ask you questions."
        case .notifications:      return "Can post macOS notifications."
        case .speak:              return "Can speak text through the system voice."
        case .runShortcuts:       return "Can run Shortcuts you already have installed."
        case .hotkeys:            return "Can claim global keyboard shortcuts."
        case .clipboard:          return "Can read and replace your clipboard."
        case .microphone:         return "Can record audio while active. Requires the mic permission."
        case .speechRecognition:  return "Transcribes audio on-device. Requires the speech permission."
        case .calendar:           return "Can list upcoming events and create new ones."
        case .automation:         return "Can send AppleScript commands to other apps."
        case .notchOverlay:       return "Owns the panel at the top of your screens."
        case .toneProfiles:       return "Reads and edits the formal/casual profile per app."
        case .snippets:           return "Reads and edits your snippet library."
        }
    }

    /// SF Symbol for the permissions screen row.
    public var iconName: String {
        switch self {
        case .observeText:        return "text.magnifyingglass"
        case .observeApps:        return "macwindow"
        case .observeKeystrokes:  return "keyboard"
        case .observeScreen:      return "rectangle.dashed.badge.record"
        case .observeProcesses:   return "terminal"
        case .insertText:         return "text.insert"
        case .popoverUI:          return "bubble.middle.top"
        case .notifications:      return "bell.badge"
        case .speak:              return "speaker.wave.2"
        case .runShortcuts:       return "square.2.layers.3d"
        case .hotkeys:            return "command"
        case .clipboard:          return "doc.on.clipboard"
        case .microphone:         return "mic"
        case .speechRecognition:  return "waveform"
        case .calendar:           return "calendar"
        case .automation:         return "applescript"
        case .notchOverlay:       return "sparkles.rectangle.stack"
        case .toneProfiles:       return "person.text.rectangle"
        case .snippets:           return "text.badge.plus"
        }
    }
}
