import Foundation
import CryptoKit

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

    static let maxCompressedBytes: Int64 = 25 * 1024 * 1024
    static let maxExtractedBytes: Int64 = 100 * 1024 * 1024
    static let maxExtractedFiles = 2_048

    enum InstallError: LocalizedError {
        case insecureURL
        case downloadFailed(String)
        case extractionFailed(String)
        case manifestMissing
        case manifestInvalid(String)
        case idMismatch(expected: String, found: String)
        case metadataMismatch(String)
        case archiveSizeMismatch(expected: Int64, found: Int64)
        case archiveHashMismatch
        case unsafeArchive(String)
        case invalidID(String)
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
            case .metadataMismatch(let field):
                return "Embedded manifest \(field) does not match the authenticated registry entry."
            case .archiveSizeMismatch(let expected, let found):
                return "Archive size mismatch (expected \(expected) bytes, received \(found))."
            case .archiveHashMismatch:
                return "Archive SHA-256 does not match the authenticated registry entry."
            case .unsafeArchive(let detail):
                return "Archive rejected — \(detail)"
            case .invalidID(let id):
                return "Registry plugin id is invalid: \(id)"
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
        guard PluginManifest.isValidID(entry.id) else { throw InstallError.invalidID(entry.id) }
        try entry.validate()
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
        try await download(from: url, to: zipURL, expectedSize: entry.archiveSize)
        try verifyArchive(zipURL, entry: entry)

        let extractDir = scratch.appending(path: "unpacked", directoryHint: .isDirectory)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try preflightArchive(zipURL)
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
        guard manifest.version == entry.version else {
            throw InstallError.metadataMismatch("version")
        }
        guard manifest.permissions == entry.permissions else {
            throw InstallError.metadataMismatch("permissions")
        }
        guard manifest.events == entry.events else {
            throw InstallError.metadataMismatch("events")
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
    @MainActor
    static func remove(id: String, directory _: URL) throws {
        let fm = FileManager.default
        let installRoot = PluginHost.installRoot
        let directory = try removalURL(for: id, installRoot: installRoot)
        let canonicalRoot = installRoot.resolvingSymlinksInPath().standardized.path
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardized.path
        guard parent == canonicalRoot else { throw InstallError.unsafeArchive("refusing deletion outside install root") }
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        Log.info("PluginInstaller: removed \(id)")
    }

    static func removalURL(for id: String, installRoot: URL) throws -> URL {
        guard PluginManifest.isValidID(id) else { throw InstallError.invalidID(id) }
        return installRoot.appending(path: id, directoryHint: .isDirectory)
    }

    // MARK: - Steps

    private static func download(from url: URL, to file: URL,
                                 expectedSize: Int64) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw InstallError.downloadFailed("server did not return HTTP")
            }
            if !(200...299).contains(http.statusCode) {
                throw InstallError.downloadFailed("server returned HTTP \(http.statusCode)")
            }
            guard response.url?.scheme?.lowercased() == "https" else {
                throw InstallError.insecureURL
            }
            if response.expectedContentLength >= 0,
               response.expectedContentLength != expectedSize {
                throw InstallError.archiveSizeMismatch(
                    expected: expectedSize, found: response.expectedContentLength)
            }

            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw InstallError.downloadFailed("could not create temporary archive")
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var received: Int64 = 0
            for try await byte in bytes {
                received += 1
                guard received <= expectedSize, received <= maxCompressedBytes else {
                    throw InstallError.unsafeArchive("compressed size limit exceeded")
                }
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            guard received == expectedSize else {
                throw InstallError.archiveSizeMismatch(expected: expectedSize, found: received)
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
    }

    static func verifyArchive(_ file: URL, entry: PluginRegistryEntry) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size <= maxCompressedBytes else { throw InstallError.unsafeArchive("compressed size limit exceeded") }
        guard size == entry.archiveSize else {
            throw InstallError.archiveSizeMismatch(expected: entry.archiveSize, found: size)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == entry.archiveSHA256.lowercased() else { throw InstallError.archiveHashMismatch }
    }

    /// Inspect the ZIP central directory before extraction so declared file
    /// count, expanded bytes, paths, and Unix entry types fail before `ditto`
    /// can write them. Exact archive hashing makes this metadata part of the
    /// reviewed artifact; post-extraction checks remain defense in depth.
    static func preflightArchive(_ zip: URL) throws {
        let summary = try runZipInfo("-t", zip: zip)
        let listing = try runZipInfo("-l", zip: zip)
        let names = try runZipInfo("-1", zip: zip)
        try validateArchiveIndex(summary: summary, listing: listing, names: names)
    }

    static func validateArchiveIndex(summary: String, listing: String, names: String,
                                     maxFiles: Int = maxExtractedFiles,
                                     maxBytes: Int64 = maxExtractedBytes) throws {
        let regex = try NSRegularExpression(pattern: #"([0-9]+) files?, ([0-9]+) bytes uncompressed"#)
        let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        guard let match = regex.firstMatch(in: summary, range: range),
              let filesRange = Range(match.range(at: 1), in: summary),
              let bytesRange = Range(match.range(at: 2), in: summary),
              let fileCount = Int(summary[filesRange]),
              let byteCount = Int64(summary[bytesRange]) else {
            throw InstallError.unsafeArchive("could not read ZIP central-directory totals")
        }
        guard fileCount <= maxFiles else {
            throw InstallError.unsafeArchive("file count limit exceeded")
        }
        guard byteCount <= maxBytes else {
            throw InstallError.unsafeArchive("expanded size limit exceeded")
        }

        for line in listing.split(separator: "\n") {
            guard let kind = line.first, "-dlbcps".contains(kind) else { continue }
            guard kind == "-" || kind == "d" else {
                throw InstallError.unsafeArchive("symlinks and special files are not allowed")
            }
        }
        for rawName in names.split(separator: "\n", omittingEmptySubsequences: false) {
            let name = String(rawName)
            if name.isEmpty { continue }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\\"),
                  !components.contains(where: { $0 == ".." }) else {
                throw InstallError.unsafeArchive("archive path escapes the extraction directory")
            }
        }
    }

    private static func runZipInfo(_ option: String, zip: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = [option, zip.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, fixed in fixed }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            throw InstallError.unsafeArchive("could not inspect ZIP central directory")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw InstallError.unsafeArchive("invalid ZIP central directory")
        }
        return text
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

        // Belt-and-suspenders: confirm containment, type, count, and expanded
        // byte limits. Symlinks and device/socket/FIFO entries are forbidden.
        let fm = FileManager.default
        let base = dir.standardized.path
        let canonicalBase = dir.resolvingSymlinksInPath().standardized.path
        var fileCount = 0
        var extractedBytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                     .isSymbolicLinkKey, .fileSizeKey]
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys) {
            for case let item as URL in enumerator {
                guard item.standardized.path.hasPrefix(base + "/") else {
                    throw InstallError.extractionFailed("archive entry escaped the extraction directory")
                }
                guard item.resolvingSymlinksInPath().standardized.path.hasPrefix(canonicalBase + "/") else {
                    throw InstallError.unsafeArchive("symbolic link escaped the extraction directory")
                }
                fileCount += 1
                guard fileCount <= maxExtractedFiles else {
                    throw InstallError.unsafeArchive("file count limit exceeded")
                }
                let values = try item.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else {
                    throw InstallError.unsafeArchive("symbolic links are not allowed")
                }
                guard values.isRegularFile == true || values.isDirectory == true else {
                    throw InstallError.unsafeArchive("special files are not allowed")
                }
                if values.isRegularFile == true {
                    extractedBytes += Int64(values.fileSize ?? 0)
                    guard extractedBytes <= maxExtractedBytes else {
                        throw InstallError.unsafeArchive("expanded size limit exceeded")
                    }
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
