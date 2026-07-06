import Foundation
import HalenPluginAPI

/// One-shot import of the standalone NotchBar app's settings into Halen's
/// defaults domain.
///
/// NotchBar persisted everything in `com.notchbar.app`; Notch Boss reads the
/// exact same key names out of `UserDefaults.standard` (Halen's domain). This
/// migrator copies every known key across — only where the destination has no
/// value yet, so nothing a user already set in Halen gets clobbered — and then
/// stamps `notchboss.migrated.v1` so it never runs again.
enum NotchBarMigrator {
    static let migrationFlagKey = "notchboss.migrated.v1"
    private static let notchBarDomain = "com.notchbar.app"

    /// Keys copied verbatim (same names on both sides). Matches AppSettings'
    /// @AppStorage keys plus `hasCompletedOnboarding`; `plugin.disabled.*`
    /// keys are matched by prefix instead (the provider set is open-ended).
    private static let migratedKeys: Set<String> = [
        // Notifications / sounds
        "playSounds",
        "notifySessionComplete",
        "notifyWaitingForInput",
        "notifyApprovalNeeded",
        // Cost tracking
        "costAlertThreshold",
        "showCostTracking",
        // Display
        "showContextWindow",
        "showContextWarning",
        "contextWarningThreshold",
        "compactMode",
        // Card sections
        "showSessionBadges",
        "showTimeline",
        "showReasoning",
        "showGitStatus",
        "showDiffs",
        "showMessageInput",
        // General
        "transcriptPollInterval",
        "defaultProvider",
        // Conflict detector
        "conflictLockExpiryMinutes",
        "conflictAutoResolve",
        "conflictFileWatcher",
        // Approvals
        "autoApproveReads",
        "autoApproveEdits",
        "autoApproveBash",
        "autoApproveAgents",
        "autoApproveManagement",
        "approvalTimeoutMinutes",
        // Onboarding marker (Notch Boss has no wizard, but keeping the flag
        // means a future re-introduction won't re-prompt NotchBar veterans)
        "hasCompletedOnboarding",
    ]

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }

        let source = readNotchBarDefaults()
        guard !source.isEmpty else {
            defaults.set(true, forKey: migrationFlagKey)
            Log.info("NotchBarMigrator: no NotchBar defaults found — nothing to migrate")
            return
        }

        var copied: [String] = []
        var kept = 0
        for (key, value) in source {
            guard migratedKeys.contains(key) || key.hasPrefix("plugin.disabled.") else { continue }
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied.append(key)
            } else {
                kept += 1
            }
        }

        defaults.set(true, forKey: migrationFlagKey)

        var summary = "NotchBarMigrator: imported \(copied.count) NotchBar setting(s)"
        if kept > 0 { summary += ", kept \(kept) existing Halen value(s)" }
        if !copied.isEmpty { summary += " — \(copied.sorted().joined(separator: ", "))" }
        Log.info(summary)
    }

    /// Read the NotchBar app's persisted defaults. Primary path is the
    /// `com.notchbar.app` suite via cfprefsd; if that yields nothing useful
    /// (e.g. the daemon has no cache for the domain), fall back to parsing
    /// `~/Library/Preferences/com.notchbar.app.plist` directly.
    private static func readNotchBarDefaults() -> [String: Any] {
        if let suite = UserDefaults(suiteName: notchBarDomain) {
            if let dict = suite.persistentDomain(forName: notchBarDomain), !dict.isEmpty {
                return dict
            }
        }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(notchBarDomain).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
