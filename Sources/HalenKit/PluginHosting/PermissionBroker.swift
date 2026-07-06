import AppKit
import ApplicationServices
import AVFoundation
import EventKit
import Foundation
import IOKit.hid
import Speech
import UserNotifications
import HalenPluginAPI

/// The one permission layer. Two jobs:
///
/// 1. **Capability grants** — per-plugin, per-capability booleans backed by
///    UserDefaults. A plugin's manifest *declares* capabilities; enabling the
///    plugin consents to them; the permissions screen lets the user revoke
///    any single one afterwards. `PluginContext` services are built from the
///    effective set (declared ∩ not-revoked), so a revoked capability is a
///    nil service, not a runtime check the plugin could forget.
///
/// 2. **System (TCC) permissions** — every macOS privacy prompt goes through
///    here so plugins never call TCC APIs themselves, and the permissions
///    screen can show one unified status list.
@MainActor
@Observable
package final class PermissionBroker {
    /// Live TCC status, shared with the permissions screen.
    package let system = SystemPermissionsModel()

    /// Bumped on every grant change so SwiftUI dependents refresh.
    package private(set) var revision = 0

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Capability grants

    private func grantKey(_ pluginId: String, _ capability: String) -> String {
        "capability.\(pluginId).\(capability)"
    }

    /// Is `capability` effective for this plugin? True iff the manifest
    /// declares it and the user hasn't revoked it. Undeclared capabilities
    /// are never granted — there is no "ask for more at runtime".
    package func isGranted(_ capability: Capability, manifest: PluginManifest) -> Bool {
        guard manifest.declaredCapabilities.contains(capability) else { return false }
        if let stored = defaults.object(forKey: grantKey(manifest.id, capability.rawValue)) as? Bool {
            return stored
        }
        return true   // declared + never touched = consented at enable time
    }

    package func setGranted(_ granted: Bool, capability: Capability, pluginId: String) {
        defaults.set(granted, forKey: grantKey(pluginId, capability.rawValue))
        revision += 1
    }

    /// The effective capability set used to build a plugin's context.
    package func effectiveCapabilities(for manifest: PluginManifest) -> Set<Capability> {
        Set(manifest.declaredCapabilities.filter { isGranted($0, manifest: manifest) })
    }

    // MARK: - System permission requests

    /// Trigger the system prompt for `permission` where the OS allows
    /// programmatic prompting, then refresh and report the outcome.
    package func request(_ permission: SystemPermission) async -> Bool {
        switch permission {
        case .accessibility:
            AXPermissions.promptForTrust()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        system.refresh()
        // Notifications resolves async inside refresh(); poll once shortly
        // after so the caller gets a settled answer for that case too.
        try? await Task.sleep(for: .milliseconds(300))
        return system.grants[permission] == .granted
    }
}

/// Per-plugin facade handed out through `PluginContext.permissions`.
@MainActor
final class PluginPermissionService: PermissionService {
    private let broker: PermissionBroker

    init(broker: PermissionBroker) {
        self.broker = broker
    }

    func status(of permission: SystemPermission) -> PermissionGrant {
        broker.system.grants[permission] ?? .checking
    }

    func request(_ permission: SystemPermission) async -> Bool {
        await broker.request(permission)
    }

    func openSystemSettings(for permission: SystemPermission) {
        permission.openSystemSettings()
    }
}
