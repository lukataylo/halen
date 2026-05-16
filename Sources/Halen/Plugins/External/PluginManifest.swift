import Foundation

/// Install-time descriptor sitting next to a plugin binary. Read by
/// `PluginHost` to know how to spawn the plugin, which events to push to it,
/// and which host-side capabilities the user agreed to expose.
///
/// Lives at `<pluginDir>/halen-plugin.json`. JSON over TOML because (a)
/// every plugin author already speaks JSON and (b) Codable handles it natively
/// with zero extra dependencies.
struct PluginManifest: Codable, Equatable {
    /// Reverse-DNS identifier. Persistence keys (enabled/disabled), TCC
    /// tracking, and on-disk install paths all key off this. Don't change
    /// after shipping.
    let id: String
    let name: String
    let summary: String?
    let version: String
    /// Plugin protocol version the plugin was written against. The host
    /// refuses to load plugins whose `halenApiVersion` it doesn't recognise.
    let halenApiVersion: String

    /// Path (absolute or relative to the manifest directory) of the
    /// executable to launch — typically a script interpreter (`/usr/bin/python3`)
    /// or a compiled binary. Validated to exist + be executable before spawn.
    let executable: String
    let args: [String]?
    let env: [String: String]?

    /// Event topics this plugin wants pushed to it. Anything not in the list
    /// is filtered before reaching the plugin's stdin — saves the plugin
    /// process the wakeups and avoids accidental data leakage.
    let events: [String]?

    /// User-visible permission declarations. Surfaced in the marketplace
    /// "Install" sheet so the user sees what the plugin is asking for before
    /// they enable it. **Today informational only** — the host trusts the
    /// plugin once enabled. Real enforcement (sandbox-exec profiles, per-
    /// permission method gating) is a follow-on.
    let permissions: [String]?

    /// SF Symbol the marketplace renders for the plugin row.
    let icon: String?
    /// Plugin category bucket (`writing` / `productivity` / `focus` / ...);
    /// falls back to "productivity" if unrecognised.
    let category: String?

    static let supportedApiVersions: Set<String> = ["0.1"]

    /// Discover all plugins under the canonical install directory:
    /// `~/Library/Application Support/Halen/Plugins/<plugin-id>/halen-plugin.json`.
    /// Each subdirectory is a self-contained plugin (manifest + binary +
    /// any local data files). Manifests that fail to parse or fail validation
    /// are logged and skipped — one bad plugin doesn't break the others.
    static func discoverAll(under root: URL) -> [(URL, PluginManifest)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])
        else { return [] }

        var results: [(URL, PluginManifest)] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = entry.appending(path: "halen-plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                try manifest.validate(at: entry)
                results.append((entry, manifest))
            } catch {
                Log.warn("PluginManifest: skipped \(manifestURL.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return results
    }

    /// Resolve `executable` against the manifest directory if it's relative,
    /// returning the absolute URL.
    func resolvedExecutable(in pluginDir: URL) -> URL {
        let path = (executable as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return pluginDir.appending(path: path)
    }

    private func validate(at pluginDir: URL) throws {
        guard Self.supportedApiVersions.contains(halenApiVersion) else {
            throw ManifestError.unsupportedApiVersion(halenApiVersion)
        }
        let exec = resolvedExecutable(in: pluginDir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: exec.path) else {
            throw ManifestError.executableMissing(exec.path)
        }
        guard fm.isExecutableFile(atPath: exec.path) else {
            throw ManifestError.notExecutable(exec.path)
        }
    }
}

enum ManifestError: Error, LocalizedError {
    case unsupportedApiVersion(String)
    case executableMissing(String)
    case notExecutable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedApiVersion(let v):
            return "Plugin requires halenApiVersion \(v), which this Halen doesn't recognise"
        case .executableMissing(let path):
            return "Plugin executable missing: \(path)"
        case .notExecutable(let path):
            return "Plugin file is not executable (chmod +x): \(path)"
        }
    }
}
