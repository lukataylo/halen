import Foundation

/// Cleanup helpers for raw text coming back from a language model.
///
/// Local models habitually wrap their answer in quotes or backticks and pad
/// it with whitespace, regardless of how firmly the prompt says "output only
/// …". Five call sites used to each strip a slightly different hand-picked
/// set of characters — a model wrapping output in backticks got cleaned in
/// some places and not others. These two extensions are the single source of
/// truth; pick the one that matches what the model was asked to produce.
extension String {

    /// Characters a model uses to *wrap* an answer: straight and curly
    /// quotes plus the backtick. Deliberately excludes sentence punctuation —
    /// `unwrappedModelText` must not eat a paragraph's trailing full stop.
    private static let modelWrapperChars =
        CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}")

    /// Generative output (a rephrase, a snippet expansion, a summary): trim
    /// surrounding whitespace, strip a layer of wrapping quotes/backticks,
    /// then re-trim whitespace the unwrap exposed (`" hello "` → `hello`).
    /// Interior and *trailing* punctuation is preserved — a rewritten
    /// paragraph keeps its full stop.
    var unwrappedModelText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: Self.modelWrapperChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A classifier's answer reduced to its first bare token, lowercased.
    /// Strips wrapping quotes/backticks AND leading/trailing sentence
    /// punctuation (`"Irritated."` → `irritated`, `"\"yes\""` → `yes`), then
    /// takes the first whitespace-delimited word. For yes/no and
    /// single-label classification prompts — never for generative output.
    var modelLabelToken: String {
        let strip = Self.modelWrapperChars.union(CharacterSet(charactersIn: ".,!?:; "))
        return lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: strip)
            .components(separatedBy: .whitespacesAndNewlines)
            .first ?? ""
    }
}
