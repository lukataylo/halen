import AppKit
import ApplicationServices

enum AXPermissions {
    /// Non-prompting check.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt that points the user at System Settings. Returns the
    /// current trust state (typically false on first call, true once the user toggles).
    @discardableResult
    static func promptForTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: NSDictionary = [key: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
