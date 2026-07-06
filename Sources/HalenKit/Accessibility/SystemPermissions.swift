import AppKit
import AVFoundation
import Speech
import EventKit
import UserNotifications
import ApplicationServices
import IOKit.hid
import HalenPluginAPI

/// Snapshot of every permission's current state, observable by SwiftUI. Owned
/// at view scope (one per Settings open) — the data is cheap to refetch and
/// shouldn't live across menubar-popup close/reopen because it could go stale
/// from under us.
@MainActor
@Observable
package final class SystemPermissionsModel {
    package private(set) var grants: [SystemPermission: PermissionGrant] = [:]

    package init() {
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
    package func refresh() {
        grants[.accessibility]     = accessibilityGrant()
        grants[.microphone]        = microphoneGrant()
        grants[.speechRecognition] = speechRecognitionGrant()
        grants[.calendar]          = calendarGrant()
        grants[.inputMonitoring]   = inputMonitoringGrant()
        grants[.screenRecording]   = screenRecordingGrant()
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
        // `.writeOnly`. Plugins that use the calendar capability *read* events
        // (the host's `calendar/upcomingEvents` JSON-RPC method), so write-only
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
        // `IOHIDRequestAccess` — here we only want to *read* the cached state.
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch status {
        case kIOHIDAccessTypeGranted:      return .granted
        case kIOHIDAccessTypeDenied:       return .denied
        case kIOHIDAccessTypeUnknown:      return .notRequested
        default:                            return .notRequested
        }
    }

    private func screenRecordingGrant() -> PermissionGrant {
        // `CGPreflightScreenCaptureAccess` is non-prompting; like AX it can't
        // distinguish never-asked from denied.
        CGPreflightScreenCaptureAccess() ? .granted : .denied
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
