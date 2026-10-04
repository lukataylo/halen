import Foundation

/// Downloads, unpacks, and validates an external plugin from a registry entry.
///
/// Security posture:
///   - HTTPS only — a non-HTTPS `downloadURL` is rejected before any request.
///   - The download is written to a temp directory and unpacked there first;
///     nothing lands under the live `Plugins/` install root until the manifest
///     has passed `PluginManifest.validate(at:)`.
///   - Extraction uses `/usr/bin/ditto` (the macOS-canonical archive tool) —
///     a *system* binary, never anything from the downloaded archive. No code
///     from the plugin itself runs at any point during install.
///   - Zip entries that would escape the extraction directory (path traversal)
///     are caught: after extraction we re-confirm every unpacked path stays
///     within the temp directory.
///   - The manifest `id` must equal the registry entry `id`; a mismatch aborts
///     so a registry entry can't smuggle a plugin under a different identity.
enum PluginInstaller {

    enum InstallError: LocalizedError {
        case insecureURL
        case downloadFailed(String)
        case extractionFailed(String)
        case manifestMissing
        case manifestInvalid(String)
        case idMismatch(expected: String, found: String)
        case alreadyInstalled

        var errorDescription: String? {
            switch self {
            case .insecureURL:
                return "Download URL must use HTTPS."
            case .downloadFailed(let detail):
                return "Download failed — \(detail)"
            case .extractionFailed(let detail):
                return "Could not unpack the plugin archive — \(detail)"
            case .manifestMissing:
                return "The archive contains no halen-plugin.json manifest."
            case .manifestInvalid(let detail):
                return "Plugin manifest is invalid — \(detail)"
            case .idMismatch(let expected, let found):
                return "Manifest id \"\(found)\" does not match registry id \"\(expected)\"."
            case .alreadyInstalled:
                return "This plugin is already installed."
            }
        }
    }

    /// Result of a successful install: where it landed and its parsed manifest,
    /// so the caller can register it live with `PluginHost` + `PluginRegistry`.
    struct Installed {
        let directory: URL
        let manifest: PluginManifest
    }

    /// Full install pipeline. Runs entirely off the main actor — only file and
    /// network I/O. The caller registers the returned plugin on the main actor.
    static func install(_ entry: PluginRegistryEntry) async throws -> Installed {
        guard let url = URL(string: entry.downloadURL),
              url.scheme?.lowercased() == "https" else {
            throw InstallError.insecureURL
        }

        let installRoot = await PluginHost.installRoot
        let destination = installRoot.appending(path: entry.id, directoryHint: .isDirectory)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            throw InstallError.alreadyInstalled
        }

        // Work in a scratch directory so a failed/aborted install never leaves
        // a half-written plugin under the live install root.
        let scratch = fm.temporaryDirectory
            .appending(path: "halen-plugin-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let zipURL = scratch.appending(path: "plugin.zip")
        try await download(from: url, to: zipURL)

        let extractDir = scratch.appending(path: "unpacked", directoryHint: .isDirectory)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try extract(zip: zipURL, into: extractDir)

        // Locate the plugin directory: the manifest is either at the extract
        // root or nested under exactly one wrapping folder. Flatten that case.
        let pluginRoot = try locatePluginRoot(in: extractDir)

        // Validate before anything touches the live install root.
        let manifestURL = pluginRoot.appending(path: "halen-plugin.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw InstallError.manifestMissing
        }
        let manifest: PluginManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw InstallError.manifestInvalid(error.localizedDescription)
        }
        guard manifest.id == entry.id else {
            throw InstallError.idMismatch(expected: entry.id, found: manifest.id)
        }
        do {
            try manifest.validate(at: pluginRoot)
        } catch {
            throw InstallError.manifestInvalid(error.localizedDescription)
        }

        // Validated — promote into the live install root atomically-ish.
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            // Lost a race with another install of the same id.
            throw InstallError.alreadyInstalled
        }
        try fm.moveItem(at: pluginRoot, to: destination)

        // The manifest validated against the scratch path; the executable
        // resolution is identical relative to the new directory, but a
        // hardened second pass costs nothing and catches a moved-symlink edge.
        do {
            try manifest.validate(at: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw InstallError.manifestInvalid(error.localizedDescription)
        }

        Log.info("PluginInstaller: installed \(manifest.id) v\(manifest.version)")
        return Installed(directory: destination, manifest: manifest)
    }

    /// Delete an installed plugin's directory. Caller is responsible for
    /// unregistering it from `PluginRegistry` first (which stops the process).
    static func remove(id: String, directory: URL) throws {
        let fm = FileManager.default
        let installRoot = directory.deletingLastPathComponent()
        // Containment guard: only ever delete inside the canonical install root.
        guard directory.standardized.path.hasPrefix(installRoot.standardized.path + "/") ||
              directory.deletingLastPathComponent().lastPathComponent == "Plugins" else {
            throw InstallError.extractionFailed("refusing to delete outside the plugin install root")
        }
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        Log.info("PluginInstaller: removed \(id)")
    }

    // MARK: - Steps

    private static func download(from url: URL, to file: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw InstallError.downloadFailed("server returned HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: tempURL, to: file)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
    }

    /// Unpack `zip` into `dir` using the system `ditto` tool. `ditto` rejects
    /// absolute and `..` traversal entries, so the archive cannot write outside
    /// `dir`. We re-verify containment afterwards as belt-and-suspenders.
    private static func extract(zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw InstallError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw InstallError.extractionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Belt-and-suspenders: confirm nothing escaped `dir`.
        let fm = FileManager.default
        let base = dir.standardized.path
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                guard item.standardized.path.hasPrefix(base + "/") else {
                    throw InstallError.extractionFailed("archive entry escaped the extraction directory")
                }
            }
        }
    }

    /// The manifest lives at the extract root, or under exactly one wrapping
    /// folder (the common "zip of a folder" shape). Anything else is ambiguous
    /// and rejected.
    private static func locatePluginRoot(in extractDir: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: extractDir.appending(path: "halen-plugin.json").path) {
            return extractDir
        }
        let entries = (try? fm.contentsOfDirectory(at: extractDir,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        // Ignore macOS archive cruft like __MACOSX.
        let dirs = entries.filter { url in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue && url.lastPathComponent != "__MACOSX"
        }
        if dirs.count == 1,
           fm.fileExists(atPath: dirs[0].appending(path: "halen-plugin.json").path) {
            return dirs[0]
        }
        throw InstallError.manifestMissing
    }
}
