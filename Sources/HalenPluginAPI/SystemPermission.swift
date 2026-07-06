import AppKit
import Foundation

/// One pane of macOS Privacy & Security that the host (or a plugin, through
/// `PermissionService`) depends on. The permissions screen iterates
/// `allCases` to render a unified status view, so surfacing a new permission
/// is a one-case-plus-implementation change.
///
/// `@MainActor` because every backing query (`AXIsProcessTrusted`, AVCapture
/// auth-status, EKEventStore.authorizationStatus, IOHIDCheckAccess) is either
/// MainActor-bound by convention or returns a value the SwiftUI views read on
/// the main actor.
@MainActor
public enum SystemPermission: String, CaseIterable, Identifiable {
    case accessibility
    case microphone
    case speechRecognition
    case calendar
    case inputMonitoring
    case notifications
    case screenRecording

    // `id` returns the raw-value string and is actor-independent. Marking
    // it `nonisolated` lets Swift 6 strict concurrency accept the
    // `Identifiable` conformance on this @MainActor enum without flagging
    // a cross-actor crossing — what's actually crossing is just a literal.
    public nonisolated var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .accessibility:     return "Accessibility"
        case .microphone:        return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .calendar:          return "Calendar"
        case .inputMonitoring:   return "Input Monitoring"
        case .notifications:     return "Notifications"
        case .screenRecording:   return "Screen Recording"
        }
    }

    /// One-line user-facing explanation of what Halen does with this permission.
    /// Shown directly under the permission name in Settings — the user can see
    /// "why does Halen want this?" without digging into docs.
    public var purpose: String {
        switch self {
        case .accessibility:     return "Caret tracking, inline corrections, snippet expansion."
        case .microphone:        return "Voice Dictation captures audio locally."
        case .speechRecognition: return "Voice Dictation transcribes audio to text."
        case .calendar:          return "Plugins with the calendar capability read your schedule."
        case .inputMonitoring:   return "Plugin hotkeys and snippet triggers in apps accessibility can't read."
        case .notifications:     return "Clipboard-fallback alerts and plugin reminders."
        case .screenRecording:   return "Only plugins with the screen capability, only on explicit grant."
        }
    }

    /// SF Symbol used in the Settings row. Picks the macOS Privacy & Security
    /// pane glyph where there's an obvious match, falls back to generic icons.
    public var iconName: String {
        switch self {
        case .accessibility:     return "accessibility"
        case .microphone:        return "mic.fill"
        case .speechRecognition: return "waveform"
        case .calendar:          return "calendar"
        case .inputMonitoring:   return "keyboard"
        case .notifications:     return "bell.badge.fill"
        case .screenRecording:   return "rectangle.dashed.badge.record"
        }
    }

    /// `x-apple.systempreferences:` deep link to the exact Privacy & Security
    /// pane for this permission. Stable across macOS 13–15; if Apple ever
    /// renames a pane anchor, only this switch needs updating. Returns nil
    /// only if we forgot to wire a case here.
    public var systemSettingsURL: URL? {
        let raw: String
        switch self {
        case .accessibility:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .calendar:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .inputMonitoring:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .notifications:
            // The bundle-specific anchor takes the user straight to Halen's
            // own row in the Notifications pane.
            raw = "x-apple.systempreferences:com.apple.preference.notifications?id=com.dadiani.halen"
        case .screenRecording:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        return URL(string: raw)
    }

    /// Open the relevant Privacy & Security pane.
    public func openSystemSettings() {
        if let url = systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What macOS says about our access to a given permission. `notRequested` and
/// `denied` look identical to the user (no functionality) but require different
/// UI affordances: `notRequested` means a feature first-use will trigger the
/// prompt; `denied` means the user must visit System Settings to revoke their
/// own previous "no" answer.
public enum PermissionGrant: Equatable, Sendable {
    case granted
    case denied
    case notRequested
    /// In-flight for permissions whose query is async (notifications).
    /// Resolves to one of the above on the next `refresh()` tick.
    case checking
}
