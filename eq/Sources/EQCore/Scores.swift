import Foundation

/// Welford running mean/variance.
public struct RunningStat: Codable, Sendable, Equatable {
    public private(set) var n = 0
    public private(set) var mean = 0.0
    private var m2 = 0.0

    public init() {}

    public mutating func add(_ x: Double) {
        n += 1
        let d = x - mean
        mean += d / Double(n)
        m2 += d * (x - mean)
    }

    public var sd: Double { n > 1 ? (m2 / Double(n - 1)).squareRoot() : 0 }
}

/// What "calm you" sounds like. Skills (pace, fillers, variety) are scored
/// against fixed targets — scoring a habit against your own average makes
/// the habit the target. Only Composure is relative to you, because
/// "heated" only means something relative to your resting voice.
public struct Baseline: Codable, Sendable, Equatable {
    /// Calm-voice pitch (semitones). Seeded by voice setup, then fed only from
    /// the quieter half of calm sessions so heated moments can't drag it up.
    public var calmPitchSt: RunningStat = .init()

    public init() {}

    public mutating func absorb(_ m: SessionMetrics) {
        guard m.speakingSeconds >= ScoreCard.minSpeech else { return }
        let a = Composure.analyse(m.windows, calm: self)
        guard a.active.count >= 6, a.spikeFraction < 0.05 else { return }
        for w in a.active where (w.relDb ?? 1) <= 0 {
            if let p = w.summary.pitchSt { calmPitchSt.add(Double(p)) }
        }
    }
}

/// One component of a score, kept so the UI can explain *why*.
public struct Factor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// 0 = on target, ~1 = notably off, capped at 3.
    public var penalty: Double
    public var detail: String
}

public struct Score: Codable, Sendable, Equatable {
    /// 0–100, or nil when there wasn't enough signal to say anything.
    public var value: Int?
    public var factors: [Factor]

    init(_ factors: [Factor], enoughSpeech: Bool) {
        self.factors = factors
        // Mean, not sum: a factor we couldn't measure must not be free points.
        guard enoughSpeech, !factors.isEmpty else { value = nil; return }
        let mean = factors.reduce(0) { $0 + ($1.penalty.isFinite ? $1.penalty : 0) } / Double(factors.count)
        value = Int((100 * exp(-mean * 0.8)).rounded())
    }

    /// The same score with factors the user said were wrong left out.
    public func without(_ disputed: Set<String>) -> Score {
        guard value != nil, factors.contains(where: { disputed.contains($0.id) }) else { return self }
        var s = Score(factors.filter { !disputed.contains($0.id) }, enoughSpeech: true)
        s.factors = factors
        return s
    }
}

/// Composure's window-level analysis, shared with `Baseline.absorb`.
public enum Composure {
    public struct Window { public var summary: WindowSummary; public var relDb: Float?; public var zPitch: Double; public var elevated: Bool }
    public struct Analysis { public var active: [Window]; public var spikeWindows: Int; public var spikeFraction: Double }

    /// A window is *elevated* when ≥2 of {pitch, loudness, pace} are up; a
    /// *spike* is ≥2 consecutive elevated windows. Loudness is relative to
    /// the session median so swapping AirPods for the laptop mic can't fake
    /// a heated moment. Pitch is relative to calm-you once set up, otherwise
    /// to this session's own median.
    public static func analyse(_ windows: [WindowSummary], calm: Baseline) -> Analysis {
        let speaking = windows.filter { $0.speaking > 0.4 }
        let medDb = Stats.median(speaking.compactMap(\.db))
        let pitches = speaking.compactMap(\.pitchSt).map(Double.init)
        let (pMean, pSd): (Double, Double) = calm.calmPitchSt.n >= 8
            ? (calm.calmPitchSt.mean, max(calm.calmPitchSt.sd, 1))
            : (Stats.median(pitches) ?? 0, max(pitches.count > 2 ? Stats.sd(pitches) : 1, 1))

        let active: [Window] = speaking.map { w in
            let rel = w.db.flatMap { d in medDb.map { d - $0 } }
            let zp = w.pitchSt.map { (Double($0) - pMean) / pSd } ?? 0
            let up = [zp > 1.5, (rel ?? 0) > 6, (w.wpm ?? 0) > 200].filter { $0 }.count
            return Window(summary: w, relDb: rel, zPitch: zp, elevated: up >= 2)
        }
        var spikes = 0, run = 0
        for w in active {
            if w.elevated { run += 1 } else { if run >= 2 { spikes += run }; run = 0 }
        }
        if run >= 2 { spikes += run }
        return Analysis(active: active, spikeWindows: spikes, spikeFraction: active.isEmpty ? 0 : Double(spikes) / Double(active.count))
    }
}

/// Presence (how you listen), Clarity (how you're understood), Composure
/// (how steady you stay).
public struct ScoreCard: Codable, Sendable, Equatable {
    public var presence: Score
    public var clarity: Score
    public var composure: Score

    /// Below this much of *your* speech, we show details but no scores.
    public static let minSpeech: Double = 180

    // Fixed, deliberately lenient skill targets.
    static let pace = (target: 150.0, scale: 20.0)
    static let fillers = (target: 3.0, scale: 2.0)
    static let variety = (target: 3.0, scale: 1.0)

    public init(metrics m: SessionMetrics, baseline b: Baseline) {
        let enough = m.speakingSeconds >= Self.minSpeech
        presence = Score(Self.presence(m), enoughSpeech: enough)
        clarity = Score(Self.clarity(m), enoughSpeech: enough)
        composure = Score(Self.composure(m, b), enoughSpeech: enough)
    }

    public var all: [Score] { [presence, clarity, composure] }

    public func without(_ disputed: Set<String>) -> ScoreCard {
        var c = self
        c.presence = presence.without(disputed); c.clarity = clarity.without(disputed); c.composure = composure.without(disputed)
        return c
    }

    static func cap(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), 3) : 0 }

    static func presence(_ m: SessionMetrics) -> [Factor] {
        var f: [Factor] = []
        if let r = m.talkRatio {
            f.append(Factor(id: "talk", label: "Talk share", penalty: cap((abs(r - 0.5) - 0.1) / 0.15),
                            detail: "You spoke \(Int((r * 100).rounded()))% of the time"))
        }
        if let i = m.interruptionsPer10Min {
            f.append(Factor(id: "interrupt", label: "Interruptions", penalty: cap((i - 1) / 2),
                            detail: String(format: "%.1f per 10 min", i)))
        }
        // A rate, so one long answer in an hour-long call doesn't dominate.
        let perHalfHour = Double(m.turnsOver90s) / max(m.duration / 1800, 1)
        f.append(Factor(id: "monologue", label: "Long monologues", penalty: cap(perHalfHour),
                        detail: m.turnsOver90s == 0 ? "None — longest \(Int(m.longestTurn)) s" : "\(m.turnsOver90s) over 90 s · longest \(Int(m.longestTurn)) s"))
        return f
    }

    static func clarity(_ m: SessionMetrics) -> [Factor] {
        var f: [Factor] = []
        if let w = m.wpm {
            f.append(Factor(id: "pace", label: "Pace", penalty: cap(abs(w - pace.target) / pace.scale - 1),
                            detail: "\(Int(w)) words/min"))
        }
        if let x = m.fillersPer100 {
            // Fillers barely move listener judgements; flag only when heavy.
            f.append(Factor(id: "fillers", label: "Um / uh", penalty: cap((x - fillers.target) / fillers.scale - 1.5),
                            detail: String(format: "%.1f per 100 words", x)))
        }
        if let x = m.pitchSdSt {
            // Only *low* variability (monotone) is penalised.
            f.append(Factor(id: "variety", label: "Vocal variety", penalty: cap((variety.target - Double(x)) / variety.scale - 1),
                            detail: String(format: "±%.1f semitones", x)))
        }
        return f
    }

    static func composure(_ m: SessionMetrics, _ b: Baseline) -> [Factor] {
        let a = Composure.analyse(m.windows, calm: b)
        guard a.active.count >= 6 else { return [] }
        let third = a.active.count / 3
        let drift: Double = {
            guard third >= 2 else { return 0 }
            func heat(_ w: Composure.Window) -> Double { w.zPitch + Double(w.relDb ?? 0) / 6 }
            return a.active.suffix(third).map(heat).reduce(0, +) / Double(third)
                 - a.active.prefix(third).map(heat).reduce(0, +) / Double(third)
        }()
        return [
            Factor(id: "spikes", label: "Heated moments", penalty: cap(a.spikeFraction / 0.1),
                   detail: a.spikeWindows == 0 ? "None" : "\(Int(Double(a.spikeWindows) * SessionMetrics.windowLength)) s in total"),
            Factor(id: "drift", label: "Escalation", penalty: cap(drift - 0.5),
                   detail: drift > 0.5 ? "More intense as it went on" : "Steady throughout"),
        ]
    }
}
