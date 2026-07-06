import Foundation

/// The one up-front declaration every plugin makes: identity, display
/// metadata, the event topics it observes, and the capabilities it requests.
///
/// First-party (in-process) plugins declare a manifest in code — see any
/// module under `Sources/Plugins/`. External plugins ship it as JSON at
/// `<pluginDir>/halen-plugin.json` next to their executable; the host reads
/// it to know how to spawn the process, which events to push to it, and
/// which host-side capabilities the user agreed to expose. JSON over TOML
/// because (a) every plugin author already speaks JSON and (b) Codable
/// handles it natively with zero extra dependencies.
public struct PluginManifest: Codable, Equatable, Sendable {
    /// Reverse-DNS identifier. Persistence keys (enabled/disabled), grant
    /// tracking, and on-disk install paths all key off this. Don't change
    /// after shipping.
    public let id: String
    public let name: String
    public let summary: String?
    public let version: String
    /// Plugin protocol version the plugin was written against. The host
    /// refuses to load plugins whose `halenApiVersion` it doesn't recognise.
    public let halenApiVersion: String

    /// Path (absolute or relative to the manifest directory) of the
    /// executable to launch — typically a script interpreter (`/usr/bin/python3`)
    /// or a compiled binary. Validated to exist + be executable before spawn.
    /// nil for in-process (first-party) plugins, which have no process.
    public let executable: String?
    public let args: [String]?
    public let env: [String: String]?

    /// Event topics this plugin wants pushed to it. Anything not in the list
    /// is filtered before reaching the plugin — saves wakeups and avoids
    /// accidental data leakage.
    public let events: [String]?

    /// Requested capabilities, as `Capability` raw values. Surfaced in the
    /// permissions screen, where each is individually revocable. Unknown
    /// strings are preserved (forward compatibility) but grant nothing.
    public let capabilities: [String]?

    /// SF Symbol the plugin list renders for the plugin row.
    public let icon: String?
    /// Plugin category bucket (`writing` / `productivity` / `focus` / ...);
    /// falls back to "productivity" if unrecognised.
    public let category: String?

    public static let supportedApiVersions: Set<String> = ["0.1"]

    public init(id: String,
                name: String,
                summary: String? = nil,
                version: String,
                halenApiVersion: String = "0.1",
                executable: String? = nil,
                args: [String]? = nil,
                env: [String: String]? = nil,
                events: [String]? = nil,
                capabilities: [String]? = nil,
                icon: String? = nil,
                category: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.halenApiVersion = halenApiVersion
        self.executable = executable
        self.args = args
        self.env = env
        self.events = events
        self.capabilities = capabilities
        self.icon = icon
        self.category = category
    }

    /// Typed convenience initializer for first-party manifests. The stringly
    /// `capabilities` field stays the storage format because JSON manifests
    /// must be able to carry values this build doesn't know yet.
    public init(id: String,
                name: String,
                summary: String? = nil,
                version: String,
                events: [String]? = nil,
                capabilities: [Capability],
                icon: String? = nil,
                category: PluginCategory) {
        self.init(id: id, name: name, summary: summary, version: version,
                  events: events,
                  capabilities: capabilities.map(\.rawValue),
                  icon: icon, category: category.rawValue)
    }

    /// The declared capabilities this build understands. Unknown strings are
    /// dropped here (they still show as "unknown" in the permissions screen
    /// via `declaredCapabilityStrings`).
    public var declaredCapabilities: [Capability] {
        (capabilities ?? []).compactMap(Capability.init(rawValue:))
    }

    /// Raw declared strings, including ones this build doesn't recognise.
    public var declaredCapabilityStrings: [String] {
        capabilities ?? []
    }

    // Decode legacy manifests that declared `permissions` instead of
    // `capabilities` — same meaning, pre-pivot name. Encoding always writes
    // `capabilities`.
    enum CodingKeys: String, CodingKey {
        case id, name, summary, version, halenApiVersion
        case executable, args, env, events, capabilities, permissions
        case icon, category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        version = try c.decode(String.self, forKey: .version)
        halenApiVersion = try c.decode(String.self, forKey: .halenApiVersion)
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        args = try c.decodeIfPresent([String].self, forKey: .args)
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        events = try c.decodeIfPresent([String].self, forKey: .events)
        let caps = try c.decodeIfPresent([String].self, forKey: .capabilities)
        let legacy = try c.decodeIfPresent([String].self, forKey: .permissions)
        capabilities = caps ?? legacy
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        category = try c.decodeIfPresent(String.self, forKey: .category)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(version, forKey: .version)
        try c.encode(halenApiVersion, forKey: .halenApiVersion)
        try c.encodeIfPresent(executable, forKey: .executable)
        try c.encodeIfPresent(args, forKey: .args)
        try c.encodeIfPresent(env, forKey: .env)
        try c.encodeIfPresent(events, forKey: .events)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(category, forKey: .category)
    }

    /// Discover all plugins under the canonical install directory:
    /// `~/Library/Application Support/Halen/Plugins/<plugin-id>/halen-plugin.json`.
    /// Each subdirectory is a self-contained plugin (manifest + binary +
    /// any local data files). Manifests that fail to parse or fail validation
    /// are logged and skipped — one bad plugin doesn't break the others.
    public static func discoverAll(under root: URL) -> [(URL, PluginManifest)] {
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
    /// alone does not check containment. nil when the manifest has no
    /// executable (in-process plugin).
    public func resolvedExecutable(in pluginDir: URL) -> URL? {
        guard let executable else { return nil }
        let path = (executable as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return pluginDir.appending(path: path)
    }

    /// Reverse-DNS-ish identifier. We persist user prefs and grant state keyed
    /// off this, and create on-disk paths from it — so anything that could
    /// turn into a path separator, a parent-directory escape, or an empty
    /// component is rejected up front.
    public static func isValidID(_ id: String) -> Bool {
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
    /// user via the permissions screen).
    public static func isExecutablePathContained(_ candidate: URL, in pluginDir: URL) -> Bool {
        // Compare standardized representations — `standardized` resolves
        // `..` and `.` components without hitting the filesystem, so symlink
        // shenanigans inside the plugin dir are still permitted (they're a
        // legitimate way to point at a venv binary) but lexical escapes
        // outside the dir are caught.
        let candidateStd = candidate.standardized.path
        let baseStd = pluginDir.standardized.path
        return candidateStd == baseStd || candidateStd.hasPrefix(baseStd + "/")
    }

    /// Validate an *external* plugin manifest against its on-disk directory.
    /// In-process manifests (no executable) never go through this — they are
    /// trusted by construction (they're compiled into the app).
    public func validate(at pluginDir: URL) throws {
        guard Self.supportedApiVersions.contains(halenApiVersion) else {
            throw ManifestError.unsupportedApiVersion(halenApiVersion)
        }
        guard Self.isValidID(id) else {
            throw ManifestError.invalidID(id)
        }
        guard let executable, let exec = resolvedExecutable(in: pluginDir) else {
            throw ManifestError.executableMissing("(none declared — external plugins must declare `executable`)")
        }
        // Relative paths must stay within pluginDir. Absolute paths are
        // user-trusted (the user dragged the plugin into place; surfacing
        // an absolute path in the permissions screen is the UX gate).
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

public enum ManifestError: Error, LocalizedError, Equatable {
    case unsupportedApiVersion(String)
    case executableMissing(String)
    case notExecutable(String)
    case invalidID(String)
    case executableOutsidePluginDir(String)

    public var errorDescription: String? {
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
