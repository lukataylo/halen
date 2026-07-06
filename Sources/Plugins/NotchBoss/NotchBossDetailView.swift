import AppKit
import Combine
import Foundation
import SwiftUI

/// Detail pane for the Notch Boss plugin. Replaces NotchBar's standalone
/// Settings window and its first-launch onboarding wizard: the provider
/// library (enable toggles, connect/disconnect, auto-approve rules, conflict
/// settings), the display settings, and the general settings all live here,
/// restacked vertically for Halen's ~380pt-wide detail pane.
struct NotchBossDetailView: View {
    @State private var notchBarRunning = false
    @State private var hookScriptReady = false

    /// Cheap liveness poll so the NotchBar warning and connection status
    /// update while the pane is open (both are filesystem/process checks).
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var hookScriptPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchbar/bin/notchbar-hook").path
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                if notchBarRunning {
                    notchBarWarningRow
                }

                claudeConnectionRow

                settingsSection("Providers") {
                    ProviderLibrarySection()
                }

                DisplaySettingsSection()

                GeneralSettingsSection()
            }
            .padding(16)
        }
        .onAppear { refreshStatus() }
        .onReceive(refresh) { _ in refreshStatus() }
    }

    private func refreshStatus() {
        notchBarRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.notchbar.app").isEmpty
        hookScriptReady = FileManager.default.isExecutableFile(atPath: hookScriptPath)
    }

    // MARK: - NotchBar-still-running warning

    /// Two apps cannot share one Unix socket or one strip of notch pixels.
    /// If the old standalone app is still running, everything here half-works,
    /// so say it loudly.
    private var notchBarWarningRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Quit the NotchBar app — Notch Boss now owns the notch and the approval socket.")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("While both run, hook events race for ~/.notchbar/notchbar.sock and approvals may land in the wrong app.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Claude Code connection (replaces the onboarding wizard)

    private var claudeConnectionRow: some View {
        settingsSection("Claude Code Connection") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(hookScriptReady ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hookScriptReady ? "Hook script installed" : "Set up Claude Code connection")
                            .font(.system(size: 13))
                        captionText(hookScriptReady
                            ? "Approvals ring the notch. Hook: ~/.notchbar/bin/notchbar-hook"
                            : "Installs the approval hook so tool calls show up in the notch.")
                    }
                    Spacer(minLength: 8)
                    Button(hookScriptReady ? "Reconnect" : "Connect") {
                        connectClaude()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(brandOrange)

                    if hookScriptReady {
                        Button("Disconnect") {
                            disconnectClaude()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    /// Same file operations as NotchBar's onboarding / menu-bar "Set Up
    /// Connection": write the hook script, then merge the PreToolUse /
    /// PostToolUse entries into ~/.claude/settings.json. Prefer the live
    /// bridge (identical behavior); fall back to the static HookManager so
    /// the button also works while the plugin is stopped.
    private func connectClaude() {
        if let controller = ProviderManager.shared?.controller(for: .claude) {
            _ = controller.installIntegration()
        } else {
            let binDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".notchbar/bin")
            try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            HookManager.writeHookScript(to: binDir)
            HookManager.installHooks(binDir: binDir)
        }
        refreshStatus()
    }

    private func disconnectClaude() {
        if let controller = ProviderManager.shared?.controller(for: .claude) {
            _ = controller.removeIntegration()
        } else {
            HookManager.removeHooks()
        }
        // Removing the settings.json entries is the real disconnect; the
        // script file stays (harmless — it fails open when nothing listens),
        // exactly like NotchBar's "Remove Connection".
        refreshStatus()
    }
}
