import Foundation

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

    static let supportedSchemaVersion = 1

    enum CodingKeys: String, CodingKey {
        case schemaVersion, halenApiVersion, plugins
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
    /// Marks an illustrative seed entry; the Store shows an "Example" tag.
    let isExample: Bool?

    var iconName: String { icon ?? "puzzlepiece.extension" }
    var isExampleEntry: Bool { isExample ?? false }

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
