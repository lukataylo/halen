import AppKit
import ServiceManagement

/// Wraps `SMAppService.mainApp` for the launch-at-login toggle in Settings.
///
/// macOS exposes four states (`SMAppService.Status`):
///   - `.notRegistered`   — never asked. Show as off.
///   - `.enabled`         — registered and approved. Will launch at login.
///   - `.requiresApproval` — registered, but the user disabled it under
///                          System Settings → Login Items. We surface this
///                          as a distinct state because the toggle alone
///                          can't fix it; the user has to re-enable in
///                          System Settings.
///   - `.notFound`        — the system can't see the app bundle. Happens in
///                          unsigned `swift run` dev builds; treat as off.
///
/// `@Observable` so SwiftUI re-renders the toggle whenever `refresh()` flips
/// the cached status (e.g. after the user returns from System Settings).
@MainActor
@Observable
final class LaunchAtLoginController {
    /// Last-known status as the system reported it. Refreshed on init, on
    /// every `setEnabled`, and whenever Settings' onAppear runs.
    private(set) var status: SMAppService.Status

    /// Last error from a `register()` or `unregister()` call, surfaced in
    /// the Settings UI when the toggle didn't take. Cleared on the next
    /// successful operation. Plain string so it can be displayed without
    /// wrapping NSError details into the view.
    private(set) var lastError: String?

    init() {
        self.status = SMAppService.mainApp.status
    }

    /// Refresh the cached `status` from the system. SwiftUI observation
    /// picks up the change and re-renders the toggle/text.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// True iff the app will actually launch on next login. `.requiresApproval`
    /// is registered-but-disabled, so the toggle should read OFF even though
    /// `SMAppService` is internally aware of us.
    var isEnabled: Bool { status == .enabled }

    /// True when our registration exists but the user has disabled it in
    /// System Settings → Login Items. We can't fix this from inside the app —
    /// only the user can re-enable from System Settings. Settings UI uses
    /// this to surface a deep-link button instead of a no-op toggle.
    var requiresApproval: Bool { status == .requiresApproval }

    /// Toggle the registration. Idempotent: registering when already
    /// `.enabled` (or unregistering when already `.notRegistered`) is a
    /// no-op success. Errors land in `lastError`.
    func setEnabled(_ value: Bool) {
        lastError = nil
        do {
            if value {
                // .register() is the modern login-item API. It writes a
                // launchd helper plist under ~/Library/LaunchAgents/ keyed
                // off the app's bundle id; macOS surfaces it under Login
                // Items → "Open at Login" for the user.
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("LaunchAtLogin: \(value ? "registered" : "unregistered")")
        } catch {
            // Common failure modes: app is unsigned (ad-hoc dev build), or
            // the bundle path is stale (LaunchServices hasn't seen the new
            // location yet). Surface to the user but don't crash.
            lastError = error.localizedDescription
            Log.warn("LaunchAtLogin: setEnabled(\(value)) failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Open System Settings → Login Items. Used when `requiresApproval` is
    /// true — re-enabling from inside our app is not possible; only the
    /// user can flip the system toggle back on.
    static func openLoginItemsSettings() {
        // x-apple.systempreferences URLs are stable across macOS versions.
        // The Login Items pane is the right anchor on macOS 13+; on older
        // macOS it falls through to the General pane (close enough).
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
