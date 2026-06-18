import Foundation

/// Installs (and removes) the bundled **Halen local-compaction** Claude Code
/// plugin when a Halen plugin that ships it is enabled / disabled.
///
/// Reasoning Compactor carries a Claude Code plugin under
/// `<pluginDir>/claude-code/` (declared via the manifest's
/// `claudeCodePluginDir`). When the user flips Reasoning Compactor **on**,
/// `ExternalPluginAdapter.start()` calls `install(fromSource:)`, which:
///
///   1. Materialises a *local Claude Code marketplace* under Halen's own
///      Application Support dir (never inside `~/.claude`, so we never fight
///      Claude Code's own bookkeeping) containing a `marketplace.json` and a
///      copy of the plugin.
///   2. Merges two keys into `~/.claude/settings.json` — `extraKnownMarketplaces`
///      (pointing at that local marketplace) and `enabledPlugins`
///      (`halen-local-compaction@halen-local: true`) — so Claude Code loads and
///      enables the plugin on its next launch. The merge is additive: every
///      other key the user has in `settings.json` is preserved untouched.
///
/// Flipping it **off** (`stop()`) removes the marketplace copy and strips just
/// those two entries back out.
///
/// All work is plain filesystem + JSON I/O and is safe to run on a background
/// task. Every step is best-effort and logged — a failure to wire up Claude
/// Code must never take down the Halen plugin that triggered it.
enum ClaudeCodeIntegration {
    /// Marketplace + plugin identity. The `enabledPlugins` key Claude Code
    /// expects is `"<pluginName>@<marketplaceName>"`.
    static let marketplaceName = "halen-local"
    static let pluginName = "halen-local-compaction"

    // MARK: - Paths

    private static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    private static var settingsURL: URL {
        claudeHome.appending(path: "settings.json")
    }

    /// Halen-owned marketplace root: `~/Library/Application Support/Halen/ClaudeCode/marketplace`.
    private static var marketplaceRoot: URL {
        HalenSupportDirectory.subdirectory("ClaudeCode/marketplace")
    }

    private static var installedPluginDir: URL {
        marketplaceRoot.appending(path: pluginName)
    }

    private static var marketplaceManifestDir: URL {
        marketplaceRoot.appending(path: ".claude-plugin")
    }

    // MARK: - Install

    /// Idempotent. Safe to call on every launch while the host plugin is
    /// enabled — it refreshes the copied plugin (so a Halen update ships new
    /// hook code) while **preserving the user's edited `config.json`**, then
    /// re-asserts the two settings keys.
    static func install(fromSource source: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            Log.warn("ClaudeCodeIntegration: source missing at \(source.path) — skipping install")
            return
        }
        do {
            try fm.createDirectory(at: marketplaceRoot, withIntermediateDirectories: true)
            try writeMarketplaceManifest()
            try refreshPluginCopy(from: source)
            try mergeSettings()
            Log.info("ClaudeCodeIntegration: installed \(pluginName) into local marketplace + ~/.claude/settings.json")
        } catch {
            Log.warn("ClaudeCodeIntegration: install failed — \(error.localizedDescription)")
        }
    }

    /// Remove the marketplace copy and strip our two settings keys back out.
    static func uninstall() {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: marketplaceRoot.path) {
                try fm.removeItem(at: marketplaceRoot)
            }
            try stripSettings()
            Log.info("ClaudeCodeIntegration: removed \(pluginName) and its settings entries")
        } catch {
            Log.warn("ClaudeCodeIntegration: uninstall failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Plugin copy

    /// Replace the installed copy with a fresh copy of `source`, carrying the
    /// user's existing `config.json` across so their frequency/type/tradeoff
    /// choices survive a plugin refresh. Built in a temp dir and swapped in to
    /// keep the live directory present for all but an instant.
    private static func refreshPluginCopy(from source: URL) throws {
        let fm = FileManager.default

        // Preserve a previously-installed, possibly user-edited config.json.
        let liveConfig = installedPluginDir.appending(path: "config.json")
        let savedConfig: Data? = fm.fileExists(atPath: liveConfig.path)
            ? try? Data(contentsOf: liveConfig)
            : nil

        let staging = marketplaceRoot.appending(path: ".\(pluginName).staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)

        // Restore the user's config over the freshly-copied default.
        if let savedConfig {
            let stagedConfig = staging.appending(path: "config.json")
            try? fm.removeItem(at: stagedConfig)
            try savedConfig.write(to: stagedConfig)
        }

        if fm.fileExists(atPath: installedPluginDir.path) {
            try fm.removeItem(at: installedPluginDir)
        }
        try fm.moveItem(at: staging, to: installedPluginDir)
    }

    private static func writeMarketplaceManifest() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: marketplaceManifestDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": marketplaceName,
            "owner": ["name": "Halen Labs"],
            "plugins": [
                [
                    "name": pluginName,
                    "source": "./\(pluginName)",
                    "description": "Compacts Claude Code context on-device with Halen's local model.",
                    "version": "1.0.0",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: marketplaceManifestDir.appending(path: "marketplace.json"))
    }

    // MARK: - settings.json merge

    /// Read `~/.claude/settings.json` (or start from `{}`), add our marketplace
    /// + enabledPlugins entries without disturbing any other key, and write it
    /// back pretty-printed.
    private static func mergeSettings() throws {
        var root = readSettings()

        var marketplaces = root["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        marketplaces[marketplaceName] = [
            "source": [
                "source": "directory",
                "path": marketplaceRoot.path,
            ],
            "autoUpdate": false,
        ]
        root["extraKnownMarketplaces"] = marketplaces

        // Keep the `enabledPlugins` key present even when otherwise empty —
        // Claude Code ignores plugin-enable edits in narrower scopes unless the
        // user-scope key already exists.
        var enabled = root["enabledPlugins"] as? [String: Any] ?? [:]
        enabled["\(pluginName)@\(marketplaceName)"] = true
        root["enabledPlugins"] = enabled

        try writeSettings(root)
    }

    private static func stripSettings() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return }
        var root = readSettings()

        if var marketplaces = root["extraKnownMarketplaces"] as? [String: Any] {
            marketplaces.removeValue(forKey: marketplaceName)
            if marketplaces.isEmpty {
                root.removeValue(forKey: "extraKnownMarketplaces")
            } else {
                root["extraKnownMarketplaces"] = marketplaces
            }
        }
        if var enabled = root["enabledPlugins"] as? [String: Any] {
            enabled.removeValue(forKey: "\(pluginName)@\(marketplaceName)")
            // Leave the (possibly empty) key in place — see mergeSettings.
            root["enabledPlugins"] = enabled
        }

        try writeSettings(root)
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
