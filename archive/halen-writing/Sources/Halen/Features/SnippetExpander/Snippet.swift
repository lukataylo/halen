import Foundation

/// One snippet entry. Three kinds:
///   - `static`: literal text. `value` holds the text.
///   - `dynamic`: computed at expansion time. `value` holds a token identifier
///     (`"today"`, `"time"`). Computed in `SnippetExpander.dynamicValue(for:)`.
///   - `ai`: feeds prior context + `value` (the user-defined system prompt) to
///     Gemma, then replaces with the response.
struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: String { trigger }
    let trigger: String              // e.g. ";sig" — must start with ";"
    let kind: Kind
    let value: String                // depends on kind (see above)
    let displayName: String
    let builtin: Bool

    /// AI snippets only: when true, the prior paragraph (back to the nearest
    /// newline) is replaced wholesale by the model output. When false / nil,
    /// the trigger token is replaced and the prior text stays intact.
    /// Examples:
    ///   - `;formal`   → replacesPrior = true (rewrite the paragraph)
    ///   - `;summary`  → replacesPrior = false (append bullets after)
    let replacesPrior: Bool?

    enum Kind: String, Codable, Sendable {
        case staticText
        case dynamic
        case ai
    }

    /// Custom init so `replacesPrior` keeps its `nil` default after the
    /// `var → let` tightening — Swift only synthesises an Optional default in
    /// the memberwise init for `var` properties.
    init(trigger: String, kind: Kind, value: String,
         displayName: String, builtin: Bool, replacesPrior: Bool? = nil) {
        self.trigger = trigger
        self.kind = kind
        self.value = value
        self.displayName = displayName
        self.builtin = builtin
        self.replacesPrior = replacesPrior
    }
}
