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

    /// Opt-in Claude Code integration. When set, the plugin ships a Claude
    /// Code plugin under `<pluginDir>/<claudeCodePluginDir>`; enabling this
    /// Halen plugin installs it into a local Claude Code marketplace and
    /// enables it in `~/.claude/settings.json`, disabling removes it
    /// (`ClaudeCodeIntegration`). Reasoning Compactor sets this to
    /// `"claude-code"`; every other plugin leaves it nil.
    let claudeCodePluginDir: String?

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
    /// returning the absolute URL. **Always pair with `validate(at:)`** —
    /// untrusted manifests can specify path-traversal segments (`../../../`)
    /// or absolute paths pointing outside the plugin directory; resolution
    /// alone does not check containment.
    func resolvedExecutable(in pluginDir: URL) -> URL {
        let path = (executable as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return pluginDir.appending(path: path)
    }

    /// Reverse-DNS-ish identifier. We persist user prefs and TCC state keyed
    /// off this, and create on-disk paths from it — so anything that could
    /// turn into a path separator, a parent-directory escape, or an empty
    /// component is rejected up front.
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        if id == "." || id == ".." { return false }
        // No path separators, no whitespace, no NUL.
        let bad: Set<Character> = ["/", "\\", " ", "\t", "\n", "\u{00}"]
        for ch in id where bad.contains(ch) { return false }
        // Forbid any literal `..` segment between dots so a clever id like
        // `com.foo..bar` can't surprise the on-disk layout.
        if id.contains("..") { return false }
        return true
    }

    /// Validate that `pluginDir.appending(path: relative).standardized` stays
    /// inside `pluginDir.standardized`. Defends against a manifest that ships
    /// `executable: "../../../usr/bin/python3"` and trusts us not to look.
    /// Absolute paths bypass this — the user installed the plugin, so an
    /// explicit absolute path is taken at face value (still surfaced to the
    /// user via the install sheet's permissions list).
    static func isExecutablePathContained(_ candidate: URL, in pluginDir: URL) -> Bool {
        // Compare standardized representations — `standardized` resolves
        // `..` and `.` components without hitting the filesystem, so symlink
        // shenanigans inside the plugin dir are still permitted (they're a
        // legitimate way to point at a venv binary) but lexical escapes
        // outside the dir are caught.
        let candidateStd = candidate.standardized.path
        let baseStd = pluginDir.standardized.path
        return candidateStd == baseStd || candidateStd.hasPrefix(baseStd + "/")
    }

    func validate(at pluginDir: URL) throws {
        guard Self.supportedApiVersions.contains(halenApiVersion) else {
            throw ManifestError.unsupportedApiVersion(halenApiVersion)
        }
        guard Self.isValidID(id) else {
            throw ManifestError.invalidID(id)
        }
        let exec = resolvedExecutable(in: pluginDir)
        // Relative paths must stay within pluginDir. Absolute paths are
        // user-trusted (the user dragged the plugin into place; surfacing
        // an absolute path in the install sheet is the UX gate).
        let executablePath = (executable as NSString).expandingTildeInPath
        if !executablePath.hasPrefix("/") {
            guard Self.isExecutablePathContained(exec, in: pluginDir) else {
                throw ManifestError.executableOutsidePluginDir(exec.path)
            }
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: exec.path) else {
            throw ManifestError.executableMissing(exec.path)
        }
        guard fm.isExecutableFile(atPath: exec.path) else {
            throw ManifestError.notExecutable(exec.path)
        }
    }
}

enum ManifestError: Error, LocalizedError, Equatable {
    case unsupportedApiVersion(String)
    case executableMissing(String)
    case notExecutable(String)
    case invalidID(String)
    case executableOutsidePluginDir(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedApiVersion(let v):
            return "Plugin requires halenApiVersion \(v), which this Halen doesn't recognise"
        case .executableMissing(let path):
            return "Plugin executable missing: \(path)"
        case .notExecutable(let path):
            return "Plugin file is not executable (chmod +x): \(path)"
        case .invalidID(let id):
            return "Plugin id \"\(id)\" is invalid (must be non-empty, contain no path separators, no `..` segments, ≤128 chars)"
        case .executableOutsidePluginDir(let path):
            return "Plugin executable resolves outside the plugin directory: \(path)"
        }
    }
}
