import Foundation

/// Acoustic "um/uh" detector. Every mainstream ASR (Parakeet, Whisper, Apple
/// SpeechTranscriber) is trained on normalised text and drops most fillers —
/// arXiv 2609.20828 measured 0.4–4 % filler recall for Parakeet. So we find
/// them in the signal instead: a filled pause is a voiced stretch with an
/// unusually *flat* pitch and steady loudness, 200–1200 ms long, that the
/// transcriber didn't turn into a real word.
public enum FilledPauses {
    public static func detect(frames: [Frame], words: [Word]) -> [Span] {
        var out: [Span] = []
        var run: [Frame] = []

        func flush() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            let span = Span(first.t, last.t)
            guard (0.2 ... 1.2).contains(span.duration) else { return }
            let st = run.compactMap(\.f0).map(Pitch.semitones)
            guard st.count >= 15 else { return }
            // Flat: within ~1 semitone, and no strong glide end-to-end.
            guard Stats.sd(st) < 0.9, abs(st.last! - st.first!) < 1.5 else { return }
            guard Stats.sd(run.map(\.db)) < 4 else { return }
            // Real words the ASR recognised are not fillers — unless the ASR
            // itself said "um".
            let covering = words.filter { Span($0.start, $0.end).overlaps(span) }
            let realWords = covering.filter { !Lexicon.fillers.contains($0.normalized) }
            let realCover = realWords.reduce(0.0) { $0 + min($1.end, span.end) - max($1.start, span.start) }
            guard realCover < span.duration * 0.3 else { return }
            out.append(span)
        }

        for f in frames {
            if f.f0 != nil { run.append(f) } else if !run.isEmpty { flush() }
        }
        flush()
        return out
    }
}
