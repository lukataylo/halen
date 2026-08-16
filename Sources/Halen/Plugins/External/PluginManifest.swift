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

    /// Relative path inside the manifest directory of the executable to
    /// launch. Validated to be contained, regular, non-symlink, and executable.
    let executable: String
    let args: [String]?
    let env: [String: String]?

    /// Event topics this plugin wants pushed to it. Anything not in the list
    /// is filtered before reaching the plugin's stdin — saves the plugin
    /// process the wakeups and avoids accidental data leakage.
    let events: [PluginEventTopic]

    /// Closed, host-enforced permission declarations. Unknown values make
    /// manifest decoding fail rather than silently becoming a grant.
    let permissions: [PluginPermission]

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
                                                       includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                       options: [.skipsHiddenFiles])
        else { return [] }

        var results: [(URL, PluginManifest)] = []
        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = entry.appending(path: "halen-plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                guard entry.lastPathComponent == manifest.id else {
                    throw ManifestError.directoryNameMismatch(expected: manifest.id,
                                                              found: entry.lastPathComponent)
                }
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
    /// Validation additionally rejects absolute paths and resolves symlinks.
    static func isExecutablePathContained(_ candidate: URL, in pluginDir: URL) -> Bool {
        // Compare standardized representations first; validate(at:) then
        // resolves the filesystem path and rejects symlinks and special files.
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
        let executablePath = (executable as NSString).expandingTildeInPath
        guard !executablePath.hasPrefix("/") else {
            throw ManifestError.absoluteExecutable(executablePath)
        }
        guard Self.isExecutablePathContained(exec, in: pluginDir) else {
            throw ManifestError.executableOutsidePluginDir(exec.path)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: exec.path) else {
            throw ManifestError.executableMissing(exec.path)
        }
        guard fm.isExecutableFile(atPath: exec.path) else {
            throw ManifestError.notExecutable(exec.path)
        }
        let canonicalBase = pluginDir.resolvingSymlinksInPath().standardized.path
        let canonicalExec = exec.resolvingSymlinksInPath().standardized.path
        guard canonicalExec.hasPrefix(canonicalBase + "/") else {
            throw ManifestError.executableOutsidePluginDir(canonicalExec)
        }
        let values = try exec.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ManifestError.specialExecutable(exec.path)
        }
    }
}

enum PluginPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case inference
    case axRead = "ax.read"
    case axWrite = "ax.write"
    case notifications
    case uiPrompt = "ui.prompt"
    case calendar
    case profilesRead = "profiles.read"
    case profilesWrite = "profiles.write"
    case hotkeys
}

/// Closed set of host data streams a plugin may request. These subscriptions
/// are surfaced separately from callable API permissions because they grant
/// ongoing access to user activity and text.
enum PluginEventTopic: String, Codable, CaseIterable, Hashable, Sendable {
    case textPause = "text.pause"
    case caretMoved = "caret.moved"
    case appFocused = "app.focused"
    case hotkeyFired = "hotkey.fired"
    case findingDetected = "finding.detected"
    case findingCleared = "finding.cleared"
}

enum ManifestError: Error, LocalizedError, Equatable {
    case unsupportedApiVersion(String)
    case executableMissing(String)
    case notExecutable(String)
    case invalidID(String)
    case executableOutsidePluginDir(String)
    case absoluteExecutable(String)
    case specialExecutable(String)
    case directoryNameMismatch(expected: String, found: String)

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
        case .absoluteExecutable(let path):
            return "Plugin executable must be relative to its plugin directory: \(path)"
        case .specialExecutable(let path):
            return "Plugin executable must be a regular, non-symlink file: \(path)"
        case .directoryNameMismatch(let expected, let found):
            return "Plugin directory must be named \"\(expected)\", not \"\(found)\""
        }
    }
}
