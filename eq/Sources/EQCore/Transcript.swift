import Foundation
import NaturalLanguage

/// One recognised word of the user's own speech, with timing.
public struct Word: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Lowercased, punctuation stripped — what lexicon matching runs on.
    public var normalized: String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

public enum Lexicon {
    /// Hesitation sounds. "like" is too ambiguous to flag from a transcript.
    /// Apple's SpeechTranscriber keeps fillers but spells "uh" as "ah" —
    /// verified 2026-10-04.
    public static let fillers: Set<String> = ["um", "uh", "ah", "erm", "er", "uhm", "umm", "uhh", "ahh", "hmm", "mm"]
}

/// Positive / negative tone of what *you* said. Valence from voice acoustics
/// is barely above chance in the wild (CCC ≤ 0.68), so tone comes from your
/// words via Apple's on-device sentiment model, and laughter from the audio.
public enum Tone {
    /// Mean sentence sentiment (−1…1), weighted by sentence length.
    public static func sentiment(_ words: [Word]) -> Double? {
        let text = words.filter { !Lexicon.fillers.contains($0.normalized) }.map(\.text).joined(separator: " ")
        guard text.split(separator: " ").count >= 15 else { return nil }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        var sum = 0.0, weight = 0.0
        tagger.enumerateTags(in: text.startIndex ..< text.endIndex, unit: .sentence, scheme: .sentimentScore, options: []) { tag, range in
            if let s = tag.flatMap({ Double($0.rawValue) }) {
                let w = Double(text[range].count)
                sum += s * w; weight += w
            }
            return true
        }
        return weight > 0 ? sum / weight : nil
    }

    public enum Mood: String, Sendable { case positive, neutral, negative
        public var label: String { switch self { case .positive: "Warm"; case .neutral: "Even"; case .negative: "Tense" } }
    }

    public static func mood(_ tone: Double?) -> Mood? {
        guard let tone else { return nil }
        return tone > 0.15 ? .positive : tone < -0.15 ? .negative : .neutral
    }
}
