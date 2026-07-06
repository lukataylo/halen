import Foundation

/// Shared persistence + ergonomics for the JSON-backed rule stores
/// (`SentimentRulesStore`, `ClarityRulesStore`, `StyleRulesStore`). Each
/// concrete store stays an `@Observable @MainActor final class` with its own
/// strongly-typed `addCustomRule(...)` (the param shapes diverge per rule
/// type), but the load / save / ensureDefaults / slug-id boilerplate that
/// used to sit ~50 lines deep in each file lives here once.
///
/// Generic inheritance off an `@Observable` base would be cleaner in the
/// abstract — but Swift's macro expansion of `@Observable` doesn't compose
/// reliably with class generics + `@MainActor`, and the resulting boilerplate-
/// on-the-subclass undoes the win. A bag of free functions is mundane but
/// keeps the call sites in each store legible.
enum JSONRuleStoreSupport {
    /// Wire format every rule store shares — `version` exists so we can
    /// migrate the on-disk shape later without breaking existing files.
    struct Payload<Rule: Codable>: Codable {
        var version: Int
        var rules: [Rule]
    }

    /// Read `Rule`s from `fileURL`. Returns `nil` on first-launch / corrupted
    /// file — callers should fall back to their builtins via `ensureDefaults`.
    /// `storeName` is logged so missing/corrupt persistence shows up keyed by
    /// plugin (otherwise three identical log lines from three stores blur).
    static func load<Rule: Codable>(_: Rule.Type, from fileURL: URL,
                                    storeName: String) -> [Rule]? {
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload<Rule>.self, from: data)
            Log.info("\(storeName): loaded \(payload.rules.count) rules")
            return payload.rules
        } catch {
            Log.debug("\(storeName): no existing file")
            return nil
        }
    }

    /// Atomic write — creates the parent directory if missing, encodes
    /// pretty-printed + sorted for human-readable diffs, replaces the file
    /// in one step. Logs at `.error` on failure (was a silent `try?` in the
    /// pre-refactor stores; one of the P2b cleanups rolled in here).
    static func save<Rule: Codable>(_ rules: [Rule], to fileURL: URL,
                                    storeName: String) {
        do {
            let payload = Payload<Rule>(version: 1, rules: rules)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            Log.error("\(storeName) save failed: \(error.localizedDescription)")
        }
    }

    /// URL-safe rule id derived from a user-typed label or term. Lowercased,
    /// spaces → underscores, stripped of anything non-alphanumeric, then
    /// suffixed with a short UUID slice so two custom rules with the same
    /// label don't collide.
    static func slugId(from text: String) -> String {
        let slug = text
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "\(slug.isEmpty ? "rule" : slug)_\(UUID().uuidString.prefix(6).lowercased())"
    }
}
