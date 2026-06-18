import SwiftUI

/// `HalenPlugin` shim around a discovered external (JSON-RPC) plugin. Lets
/// `PluginRegistry` treat external plugins exactly like first-party ones —
/// they appear in the marketplace, get an enable/disable toggle, persist
/// their on/off state in UserDefaults, and surface a detail view showing
/// the manifest metadata + permission declarations.
///
/// `start()` / `stop()` round-trip into `PluginHost.spawn(...)` /
/// `terminate(id:)` so the on/off toggle actually launches or polite-
/// shuts-down the child process. Without this adapter, external plugins
/// would run silently in the background with no UI surface at all — exactly
/// the gap a v1 plugin platform shouldn't have.
@MainActor
final class ExternalPluginAdapter: HalenPlugin {
    let manifest: PluginManifest
    let pluginDir: URL
    private weak var host: PluginHost?

    var id: String      { manifest.id }
    var name: String    { manifest.name }
    var summary: String { manifest.summary ?? "External plugin." }
    /// SF Symbol from the manifest, or a sensible "extension piece" fallback.
    var icon: String    { manifest.icon ?? "puzzlepiece.extension" }
    var category: PluginCategory {
        if let raw = manifest.category, let cat = PluginCategory(rawValue: raw) {
            return cat
        }
        return .productivity
    }

    init(manifest: PluginManifest, pluginDir: URL, host: PluginHost) {
        self.manifest = manifest
        self.pluginDir = pluginDir
        self.host = host
    }

    func start() {
        guard let host else { return }
        let dir = pluginDir
        let m = manifest
        Task { @MainActor in await host.spawn(at: dir, manifest: m) }
        installClaudeCodeIntegrationIfNeeded()
    }

    func stop() {
        guard let host else { return }
        let id = manifest.id
        Task { @MainActor in await host.terminate(id: id) }
        removeClaudeCodeIntegrationIfNeeded()
    }

    /// If the manifest opts into the Claude Code integration, install the
    /// bundled Claude Code plugin off the main actor (pure file/JSON I/O).
    /// `start()` runs on every launch while the plugin is enabled, so this is
    /// written to be idempotent and to preserve the user's edited config.
    private func installClaudeCodeIntegrationIfNeeded() {
        guard let subdir = manifest.claudeCodePluginDir else { return }
        let source = pluginDir.appending(path: subdir)
        Task.detached(priority: .utility) {
            ClaudeCodeIntegration.install(fromSource: source)
        }
    }

    /// Only reached when the user explicitly disables the plugin (app-quit
    /// shutdown terminates instances directly, not through the adapter), so
    /// removing the Claude Code integration here matches the toggle's intent.
    private func removeClaudeCodeIntegrationIfNeeded() {
        guard manifest.claudeCodePluginDir != nil else { return }
        Task.detached(priority: .utility) {
            ClaudeCodeIntegration.uninstall()
        }
    }

    func makeDetailView() -> AnyView {
        AnyView(ExternalPluginDetailView(manifest: manifest, pluginDir: pluginDir))
    }
}

/// Marketplace detail view for an external plugin. Shows the manifest fields
/// the user might want to verify before trusting the plugin — id, version,
/// the actual executable that runs, declared permissions, where it lives on
/// disk. Permissions are surfaced even though the host doesn't enforce them
/// yet (informational v1), because they're the user's only signal of what
/// surface area the plugin is asking for.
@MainActor
private struct ExternalPluginDetailView: View {
    let manifest: PluginManifest
    let pluginDir: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                identityCard
                if manifest.claudeCodePluginDir != nil {
                    claudeCodeCard
                }
                permissionsCard
                aboutCard
            }
            .padding(12)
        }
    }

    /// Shown only for a plugin that ships a Claude Code integration (Reasoning
    /// Compactor). Tells the user that enabling the plugin wires up Claude Code
    /// to compact on-device, and how to tune it.
    private var claudeCodeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Claude Code")
                Text("Enabling this plugin installs a Claude Code plugin (\(ClaudeCodeIntegration.pluginName)) that compacts Claude Code's context using Halen's on-device model — your conversation never goes to the cloud for the summary. Disabling it removes the plugin again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Configure frequency, type and tradeoffs in Claude Code with /\(ClaudeCodeIntegration.pluginName):configure. Requires Halen to be running.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var identityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Plugin")
                infoRow("ID",         manifest.id,            mono: true)
                infoRow("Version",    manifest.version,       mono: true)
                infoRow("Executable", manifest.executable,    mono: true)
                infoRow("Directory",  pluginDir.path,         mono: true)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([pluginDir])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Declared permissions")
                let perms = manifest.permissions ?? []
                if perms.isEmpty {
                    Text("This plugin declared no permissions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(perms, id: \.self) { perm in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(perm)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
                Text("Permission enforcement is informational in v1 — the host trusts any installed plugin. A sandboxed exec ladder is on the roadmap.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("About")
                Text(manifest.summary ?? "External plugin discovered under ~/Library/Application Support/Halen/Plugins/. Communicates with Halen over a JSON-RPC stdio protocol.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
