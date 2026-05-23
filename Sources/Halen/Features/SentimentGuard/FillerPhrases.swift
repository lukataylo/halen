import Foundation

/// A wordy phrase paired with a tighter replacement. Pure data — the
/// conciseness scan that uses this is rule-based and instant, no model call.
struct FillerPhrase {
    let phrase: String
    let suggestion: String
}

/// One hit from scanning text for filler phrases.
struct FillerMatch: Identifiable {
    let id = UUID().uuidString
    let phrase: String
    let suggestion: String
}

/// Static dictionary of common filler / wordy phrases with tighter rewrites.
/// Used by Sentiment Guard's conciseness check — a zero-cost scan that runs
/// alongside the tone classifier (conciseness isn't a tone, so it must not be
/// folded into the single-label tone classifier).
enum FillerPhrases {
    static let all: [FillerPhrase] = [
        .init(phrase: "in order to", suggestion: "to"),
        .init(phrase: "the fact that", suggestion: "that"),
        .init(phrase: "at this point in time", suggestion: "now"),
        .init(phrase: "at the present time", suggestion: "now"),
        .init(phrase: "due to the fact that", suggestion: "because"),
        .init(phrase: "in the event that", suggestion: "if"),
        .init(phrase: "a large number of", suggestion: "many"),
        .init(phrase: "a majority of", suggestion: "most"),
        .init(phrase: "for the purpose of", suggestion: "to"),
        .init(phrase: "in spite of the fact that", suggestion: "although"),
        .init(phrase: "with regard to", suggestion: "about"),
        .init(phrase: "with respect to", suggestion: "about"),
        .init(phrase: "in the near future", suggestion: "soon"),
        .init(phrase: "it is important to note that", suggestion: "drop it"),
        .init(phrase: "needless to say", suggestion: "drop it"),
        .init(phrase: "each and every", suggestion: "every"),
        .init(phrase: "first and foremost", suggestion: "first"),
        .init(phrase: "end result", suggestion: "result"),
        .init(phrase: "future plans", suggestion: "plans"),
        .init(phrase: "past history", suggestion: "history"),
        .init(phrase: "absolutely essential", suggestion: "essential"),
        .init(phrase: "completely eliminate", suggestion: "eliminate"),
        .init(phrase: "as a matter of fact", suggestion: "in fact"),
        .init(phrase: "on a regular basis", suggestion: "regularly"),
        .init(phrase: "in a timely manner", suggestion: "promptly"),
        .init(phrase: "has the ability to", suggestion: "can"),
        .init(phrase: "is able to", suggestion: "can"),
        .init(phrase: "in the course of", suggestion: "during"),
        .init(phrase: "a number of", suggestion: "several"),
        .init(phrase: "at all times", suggestion: "always"),
    ]

    /// Case-insensitive scan. Returns one match per distinct phrase found, in
    /// the order the phrases appear in `text`.
    static func scan(_ text: String) -> [FillerMatch] {
        let lower = text.lowercased()
        var hits: [(offset: String.Index, match: FillerMatch)] = []
        for entry in all {
            if let range = lower.range(of: entry.phrase) {
                hits.append((range.lowerBound,
                             FillerMatch(phrase: entry.phrase, suggestion: entry.suggestion)))
            }
        }
        return hits.sorted { $0.offset < $1.offset }.map(\.match)
    }
}
