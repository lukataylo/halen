import Foundation

/// One snippet entry. Three kinds:
///   - `static`: literal text. `value` holds the text.
///   - `dynamic`: computed at expansion time. `value` holds a token identifier
///     (`"today"`, `"time"`). Computed in `SnippetExpander.dynamicValue(for:)`.
///   - `ai`: feeds prior context + `value` (the user-defined system prompt) to
///     Gemma, then replaces with the response.
struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: String { trigger }
    var trigger: String              // e.g. ";sig" — must start with ";"
    var kind: Kind
    var value: String                // depends on kind (see above)
    var displayName: String
    var builtin: Bool

    /// AI snippets only: when true, the prior paragraph (back to the nearest
    /// newline) is replaced wholesale by the model output. When false / nil,
    /// the trigger token is replaced and the prior text stays intact.
    /// Examples:
    ///   - `;formal`   → replacesPrior = true (rewrite the paragraph)
    ///   - `;summary`  → replacesPrior = false (append bullets after)
    var replacesPrior: Bool?

    enum Kind: String, Codable, Sendable {
        case staticText
        case dynamic
        case ai
    }
}
