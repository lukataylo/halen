import Foundation
import CryptoKit

/// Codable mirror of `plugin-registry.json` — the curated index of installable
/// external plugins fetched over HTTPS from the Halen repo. This is *only* an
/// index: nothing here is trusted to run. On install the Store downloads the
/// entry's zip, unpacks it, and re-validates the embedded `halen-plugin.json`
/// with `PluginManifest.validate(at:)` before the plugin is ever registered.
///
/// Schema is documented in `plugin-registry.schema.md` at the repo root.
struct PluginRegistryIndex: Codable {
    /// Registry schema version. The Store refuses indexes whose version it
    /// does not recognise rather than guessing at unknown-shaped data.
    let schemaVersion: Int
    let halenApiVersion: String?
    let plugins: [PluginRegistryEntry]

    static let supportedSchemaVersion = 2
    static let maxResponseBytes = 512 * 1024

    /// Updated only with an app release after reviewing the exact registry.
    /// A network response with any byte changed is rejected before decoding.
    static let expectedSHA256 = "ff767ec18df80bfbd32b19fa3e97afd3ad434cff01d08efc209732ee9e344a69"

    static func decodeAuthenticated(_ data: Data,
                                    expectedSHA256 expectedDigest: String = PluginRegistryIndex.expectedSHA256) throws -> Self {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedDigest.lowercased() else {
            throw RegistryError.authenticationFailed
        }
        let index = try JSONDecoder().decode(Self.self, from: data)
        guard index.schemaVersion == supportedSchemaVersion else {
            throw RegistryError.unsupportedSchema(index.schemaVersion)
        }
        guard Set(index.plugins.map(\.id)).count == index.plugins.count else {
            throw RegistryError.invalidEntry("duplicate plugin id")
        }
        for entry in index.plugins { try entry.validate() }
        return index
    }

    /// Stream into a small bounded buffer before authenticating. The registry
    /// is currently under 1 KiB; a 512 KiB ceiling leaves ample growth room
    /// without letting a compromised endpoint exhaust app memory first.
    static func fetchAuthenticated(from url: URL) async throws -> Self {
        guard url.scheme?.lowercased() == "https" else {
            throw RegistryError.invalidResponse("registry URL is not HTTPS")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw RegistryError.invalidResponse("registry server returned a non-success response")
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw RegistryError.invalidResponse("registry redirected outside HTTPS")
        }
        if response.expectedContentLength > Int64(maxResponseBytes) {
            throw RegistryError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxResponseBytes,
                                 max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maxResponseBytes else {
                throw RegistryError.responseTooLarge
            }
            data.append(byte)
        }
        return try decodeAuthenticated(data)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, halenApiVersion, plugins
    }
}

enum RegistryError: LocalizedError, Equatable {
    case authenticationFailed
    case unsupportedSchema(Int)
    case invalidEntry(String)
    case invalidResponse(String)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "Plugin registry authentication failed. Update Halen to receive a reviewed registry."
        case .unsupportedSchema(let version): return "Plugin registry schema v\(version) is unsupported."
        case .invalidEntry(let detail): return "Plugin registry entry is invalid: \(detail)"
        case .invalidResponse(let detail): return "Plugin registry request failed: \(detail)."
        case .responseTooLarge: return "Plugin registry response exceeded the safety limit."
        }
    }
}

/// One installable plugin as advertised by the registry. Field semantics are
/// documented in `plugin-registry.schema.md`.
struct PluginRegistryEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let author: String
    let version: String
    let icon: String?
    let category: String?
    /// HTTPS URL of the plugin's source repo (shown as "View source").
    let sourceURL: String
    /// HTTPS URL of a zip of the plugin directory.
    let downloadURL: String
    /// Authenticated metadata for the exact downloadable bytes.
    let archiveSHA256: String
    let archiveSize: Int64
    /// Must exactly match the embedded manifest.
    let permissions: [PluginPermission]
    let events: [PluginEventTopic]
    /// Marks an illustrative seed entry; the Store shows an "Example" tag.
    let isExample: Bool?

    var iconName: String { icon ?? "puzzlepiece.extension" }
    var isExampleEntry: Bool { isExample ?? false }

    func validate() throws {
        guard PluginManifest.isValidID(id) else { throw RegistryError.invalidEntry("invalid id \(id)") }
        guard archiveSize > 0, archiveSize <= PluginInstaller.maxCompressedBytes else {
            throw RegistryError.invalidEntry("archiveSize out of bounds for \(id)")
        }
        let hashChars = CharacterSet(charactersIn: "0123456789abcdef")
        guard archiveSHA256 == archiveSHA256.lowercased(), archiveSHA256.count == 64,
              archiveSHA256.lowercased().unicodeScalars.allSatisfy(hashChars.contains) else {
            throw RegistryError.invalidEntry("archiveSHA256 is not 64 lowercase hex characters for \(id)")
        }
        guard let download = URL(string: downloadURL), download.scheme?.lowercased() == "https",
              let source = URL(string: sourceURL), source.scheme?.lowercased() == "https" else {
            throw RegistryError.invalidEntry("URLs must use HTTPS for \(id)")
        }
        guard Set(events).count == events.count, Set(permissions).count == permissions.count else {
            throw RegistryError.invalidEntry("duplicate permissions or events for \(id)")
        }
    }

    /// `category` mapped onto the in-app enum; defaults to `.productivity`
    /// for an absent or unrecognised value (category is informational only —
    /// the dropdown no longer groups by it).
    var resolvedCategory: PluginCategory {
        guard let raw = category, let cat = PluginCategory(rawValue: raw) else {
            return .productivity
        }
        return cat
    }
}
