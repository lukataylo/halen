import AppKit
import AVFoundation
import Speech
import EventKit
import UserNotifications
import ApplicationServices
import IOKit.hid

/// One pane of macOS Privacy & Security that Halen depends on. The Settings
/// "Permissions" card iterates `allCases` to render a unified status view, so
/// adding a permission Halen wants to surface is a one-case-plus-implementation
/// change.
///
/// `@MainActor` because every backing query (`AXIsProcessTrusted`, AVCapture
/// auth-status, EKEventStore.authorizationStatus, IOHIDCheckAccess) is either
/// MainActor-bound by convention or returns a value the SwiftUI views read on
/// the main actor.
@MainActor
enum SystemPermission: String, CaseIterable, Identifiable {
    case accessibility
    case microphone
    case speechRecognition
    case calendar
    case inputMonitoring
    case notifications

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility:     return "Accessibility"
        case .microphone:        return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .calendar:          return "Calendar"
        case .inputMonitoring:   return "Input Monitoring"
        case .notifications:     return "Notifications"
        }
    }

    /// One-line user-facing explanation of what Halen does with this permission.
    /// Shown directly under the permission name in Settings — the user can see
    /// "why does Halen want this?" without digging into docs.
    var purpose: String {
        switch self {
        case .accessibility:     return "Caret tracking, inline corrections, snippet expansion."
        case .microphone:        return "Voice Dictation captures audio locally."
        case .speechRecognition: return "Voice Dictation transcribes audio to text."
        case .calendar:          return "Burnout Copilot breaks, Meeting Prep briefings."
        case .inputMonitoring:   return "Ask Halen palette hotkey (⌃H) from any app."
        case .notifications:     return "Burnout reminders and Meeting Prep alerts."
        }
    }

    /// SF Symbol used in the Settings row. Picks the macOS Privacy & Security
    /// pane glyph where there's an obvious match, falls back to generic icons.
    var iconName: String {
        switch self {
        case .accessibility:     return "accessibility"
        case .microphone:        return "mic.fill"
        case .speechRecognition: return "waveform"
        case .calendar:          return "calendar"
        case .inputMonitoring:   return "keyboard"
        case .notifications:     return "bell.badge.fill"
        }
    }

    /// `x-apple.systempreferences:` deep link to the exact Privacy & Security
    /// pane for this permission. Stable across macOS 13–15; if Apple ever
    /// renames a pane anchor, only this switch needs updating. Returns nil
    /// only if we forgot to wire a case here.
    var systemSettingsURL: URL? {
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
        }
        return URL(string: raw)
    }

    /// Open the relevant Privacy & Security pane.
    func openSystemSettings() {
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
enum PermissionGrant: Equatable {
    case granted
    case denied
    case notRequested
    /// In-flight for permissions whose query is async (notifications).
    /// Resolves to one of the above on the next `refresh()` tick.
    case checking
}

/// Snapshot of every permission's current state, observable by SwiftUI. Owned
/// at view scope (one per Settings open) — the data is cheap to refetch and
/// shouldn't live across menubar-popup close/reopen because it could go stale
/// from under us.
@MainActor
@Observable
final class SystemPermissionsModel {
    private(set) var grants: [SystemPermission: PermissionGrant] = [:]

    init() {
        // Populate synchronously where we can so the Settings view doesn't
        // flash an empty list on first open.
        for permission in SystemPermission.allCases {
            grants[permission] = .checking
        }
        refresh()
    }

    /// Re-query every macOS permission API. Cheap — all calls are non-prompting
    /// status reads. Call from `Settings.onAppear` and again whenever the user
    /// returns from System Settings (where they may have just toggled something).
    func refresh() {
        grants[.accessibility]     = accessibilityGrant()
        grants[.microphone]        = microphoneGrant()
        grants[.speechRecognition] = speechRecognitionGrant()
        grants[.calendar]          = calendarGrant()
        grants[.inputMonitoring]   = inputMonitoringGrant()
        // Notifications is the only async query — kick off the lookup and
        // settle the cell on its completion.
        grants[.notifications]     = .checking
        Task { @MainActor [weak self] in
            let resolved = await Self.notificationsGrant()
            self?.grants[.notifications] = resolved
        }
    }

    // MARK: - Individual queries

    private func accessibilityGrant() -> PermissionGrant {
        // `AXIsProcessTrusted()` doesn't distinguish "never asked" from "user
        // said no" — both return false. Halen prompts on first launch via
        // `AXPermissions.promptForTrust()`, so by the time Settings is open
        // this answer is decisive.
        AXIsProcessTrusted() ? .granted : .denied
    }

    private func microphoneGrant() -> PermissionGrant {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:                  return .granted
        case .denied, .restricted:         return .denied
        case .notDetermined:               return .notRequested
        @unknown default:                  return .denied
        }
    }

    private func speechRecognitionGrant() -> PermissionGrant {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:                  return .granted
        case .denied, .restricted:         return .denied
        case .notDetermined:               return .notRequested
        @unknown default:                  return .denied
        }
    }

    private func calendarGrant() -> PermissionGrant {
        // macOS 14 split EKAuthorizationStatus into `.fullAccess` and
        // `.writeOnly`. Halen *reads* events (Burnout Copilot's
        // calendar-density signal, Meeting Prep's briefings), so write-only
        // is functionally insufficient and surfaced as denied.
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:                  return .granted
        case .writeOnly:                   return .denied
        case .authorized:                  return .granted   // pre-macOS-14
        case .denied, .restricted:         return .denied
        case .notDetermined:               return .notRequested
        @unknown default:                  return .denied
        }
    }

    private func inputMonitoringGrant() -> PermissionGrant {
        // `IOHIDCheckAccess` is the non-prompting variant of
        // `IOHIDRequestAccess`. AskHalen uses the latter on first launch;
        // here we only want to *read* the cached state.
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch status {
        case kIOHIDAccessTypeGranted:      return .granted
        case kIOHIDAccessTypeDenied:       return .denied
        case kIOHIDAccessTypeUnknown:      return .notRequested
        default:                            return .notRequested
        }
    }

    private static func notificationsGrant() async -> PermissionGrant {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized,
             .provisional,
             .ephemeral:                   return .granted
        case .denied:                      return .denied
        case .notDetermined:               return .notRequested
        @unknown default:                  return .denied
        }
    }
}
