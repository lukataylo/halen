import Foundation

/// Five-second summary used for the session timeline and for Composure,
/// which looks for stretches where you departed sharply from your calm self.
public struct WindowSummary: Codable, Sendable, Equatable {
    public var start: Double
    /// Fraction of the window you were speaking.
    public var speaking: Double
    public var pitchSt: Float?
    public var db: Float?
    public var wpm: Double?

    public init(start: Double, speaking: Double, pitchSt: Float?, db: Float?, wpm: Double?) {
        self.start = start; self.speaking = speaking; self.pitchSt = pitchSt; self.db = db; self.wpm = wpm
    }
}

/// Everything we keep about a conversation once the audio is gone.
public struct SessionMetrics: Codable, Sendable, Equatable {
    public var duration: Double
    public var speakingSeconds: Double

    // Clarity
    public var wpm: Double?
    public var fillersPer100: Double?
    public var pitchSdSt: Float?

    // Presence
    public var longestTurn: Double
    public var turnsOver90s: Int
    /// Only when the far-end level meter ran (calls with audio-capture permission).
    public var talkRatio: Double?
    public var interruptionsPer10Min: Double?
    public var medianResponseLatency: Double?

    // Tone — shown, never scored.
    /// Mean sentiment of your own sentences, −1…1 (Apple NaturalLanguage).
    public var tone: Double?
    public var laughs: Int = 0

    /// Seconds of mic audio the voice check rejected as not-you.
    public var ignoredSeconds: Double = 0
    public var voiceChecked = false

    public var windows: [WindowSummary]

    public static let windowLength: Double = 5
}

extension SessionMetrics {
    /// Fields added after v0.1 decode with defaults, so older sessions keep
    /// opening (and are never mistaken for corrupt files).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        duration = try c.decode(Double.self, forKey: .duration)
        speakingSeconds = try c.decode(Double.self, forKey: .speakingSeconds)
        wpm = try c.decodeIfPresent(Double.self, forKey: .wpm)
        fillersPer100 = try c.decodeIfPresent(Double.self, forKey: .fillersPer100)
        pitchSdSt = try c.decodeIfPresent(Float.self, forKey: .pitchSdSt)
        longestTurn = try c.decodeIfPresent(Double.self, forKey: .longestTurn) ?? 0
        turnsOver90s = try c.decodeIfPresent(Int.self, forKey: .turnsOver90s) ?? 0
        talkRatio = try c.decodeIfPresent(Double.self, forKey: .talkRatio)
        interruptionsPer10Min = try c.decodeIfPresent(Double.self, forKey: .interruptionsPer10Min)
        medianResponseLatency = try c.decodeIfPresent(Double.self, forKey: .medianResponseLatency)
        tone = try c.decodeIfPresent(Double.self, forKey: .tone)
        laughs = try c.decodeIfPresent(Int.self, forKey: .laughs) ?? 0
        ignoredSeconds = try c.decodeIfPresent(Double.self, forKey: .ignoredSeconds) ?? 0
        voiceChecked = try c.decodeIfPresent(Bool.self, forKey: .voiceChecked) ?? false
        windows = try c.decodeIfPresent([WindowSummary].self, forKey: .windows) ?? []
    }
}

public enum MetricsBuilder {
    public static func build(frames: [Frame], words: [Word], other: [Span]?, duration: Double) -> SessionMetrics {
        let speech = Activity.speechSpans(frames)
        let speaking = speech.reduce(0) { $0 + $1.duration }
        let turns = Activity.turns(own: speech, other: other)
        let turnTime = turns.reduce(0) { $0 + $1.duration }
        let realWords = words.filter { !Lexicon.fillers.contains($0.normalized) }.count
        let minutes = max(duration / 60, 1e-9)
        let voiced = frames.compactMap(\.f0).map(Pitch.semitones)

        var m = SessionMetrics(
            duration: duration,
            speakingSeconds: speaking,
            wpm: turnTime > 5 && realWords > 0 ? Double(realWords) / turnTime * 60 : nil,
            fillersPer100: words.count >= 20 ? Double(fillerCount(frames: frames, words: words)) * 100 / Double(words.count) : nil,
            pitchSdSt: voiced.count > 50 ? Stats.sd(voiced) : nil,
            longestTurn: turns.map(\.duration).max() ?? 0,
            turnsOver90s: turns.filter { $0.duration > 90 }.count,
            tone: Tone.sentiment(words),
            windows: windows(frames: frames, words: words, speech: speech, duration: duration)
        )

        if let other {
            let otherTime = other.reduce(0) { $0 + $1.duration }
            if speaking + otherTime > 10 { m.talkRatio = speaking / (speaking + otherTime) }
            m.interruptionsPer10Min = Double(interruptions(own: turns, other: other)) / minutes * 10
            m.medianResponseLatency = Stats.median(responseLatencies(own: turns, other: other))
        }
        return m
    }

    /// Acoustic filled pauses, plus any "um" the ASR kept that the acoustic
    /// pass missed.
    static func fillerCount(frames: [Frame], words: [Word]) -> Int {
        let acoustic = FilledPauses.detect(frames: frames, words: words)
        let asrOnly = words.filter { w in
            Lexicon.fillers.contains(w.normalized) && !acoustic.contains { $0.overlaps(Span(w.start, w.end)) }
        }
        return acoustic.count + asrOnly.count
    }

    /// You started a turn while they had been talking for ≥ 0.5 s and kept
    /// talking for ≥ 0.3 s more. Backchannels ("mm", "right") are shorter
    /// than a turn and so don't count.
    static func interruptions(own: [Span], other: [Span]) -> Int {
        own.filter { t in
            guard t.duration > 1 else { return false }
            return other.contains { o in o.start <= t.start - 0.5 && o.end >= t.start + 0.3 }
        }.count
    }

    /// Gap between them finishing and you starting, when you reply within 3 s.
    static func responseLatencies(own: [Span], other: [Span]) -> [Double] {
        other.compactMap { o in
            guard let next = own.first(where: { $0.start >= o.end - 0.2 }) else { return nil }
            let gap = next.start - o.end
            return gap <= 3 ? max(gap, 0) : nil
        }
    }

    static func windows(frames: [Frame], words: [Word], speech: [Span], duration: Double) -> [WindowSummary] {
        let n = Int((duration / SessionMetrics.windowLength).rounded(.up))
        guard n > 0 else { return [] }
        var buckets = Array(repeating: [Frame](), count: n)
        for f in frames { buckets[min(Int(f.t / SessionMetrics.windowLength), n - 1)].append(f) }
        return buckets.enumerated().map { i, fs in
            let w = Span(Double(i) * SessionMetrics.windowLength, Double(i + 1) * SessionMetrics.windowLength)
            let talk = speech.reduce(0.0) { acc, s in acc + max(0, min(s.end, w.end) - max(s.start, w.start)) }
            let f0 = fs.compactMap(\.f0).map(Pitch.semitones)
            let loud = fs.filter { $0.db > ProsodyExtractor.silenceDb }.map(\.db)
            let wc = words.filter { $0.start >= w.start && $0.start < w.end }.count
            return WindowSummary(
                start: w.start,
                speaking: talk / SessionMetrics.windowLength,
                pitchSt: f0.count >= 20 ? Stats.mean(f0) : nil,
                db: loud.count >= 20 ? Stats.mean(loud) : nil,
                wpm: talk > 2 ? Double(wc) / talk * 60 : nil
            )
        }
    }
}

public enum Stats {
    public static func mean<T: BinaryFloatingPoint>(_ x: [T]) -> T { x.reduce(0, +) / T(x.count) }
    public static func sd<T: BinaryFloatingPoint>(_ x: [T]) -> T {
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / T(max(x.count - 1, 1))).squareRoot()
    }
    public static func median<T: BinaryFloatingPoint>(_ x: [T]) -> T? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    /// Pearson correlation; nil when either side has no variance.
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 2 else { return nil }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) { sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my) }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}
