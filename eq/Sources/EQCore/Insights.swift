import Foundation

/// Turns many sessions into the few things worth saying.
public enum Insights {
    public enum Dimension: String, CaseIterable, Sendable {
        case presence = "Presence", clarity = "Clarity", composure = "Composure"
        public func score(_ c: ScoreCard) -> Score { switch self { case .presence: c.presence; case .clarity: c.clarity; case .composure: c.composure } }

        public init?(factorID: String) {
            switch factorID {
            case "talk", "interrupt", "monologue": self = .presence
            case "pace", "fillers", "variety": self = .clarity
            case "spikes", "drift": self = .composure
            default: return nil
            }
        }
    }

    /// Per-day scores for the last `days` days, oldest first (nil = no calls).
    public static func daily(_ dim: Dimension, _ rs: [SessionRecord], days: Int = 7, now: Date = .now) -> [(day: Date, value: Int?)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0 ..< days).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            return (day, score(dim, rs.filter { cal.isDate($0.startedAt, inSameDayAs: day) }))
        }
    }

    /// Speaking-time-weighted score across sessions (one helper for Today,
    /// Week, and the menu, so they always agree).
    public static func score(_ dim: Dimension, _ rs: [SessionRecord]) -> Int? {
        let pts = rs.compactMap { r in dim.score(r.effectiveScores).value.map { (Double($0), max(r.metrics.speakingSeconds, 1)) } }
        let w = pts.reduce(0) { $0 + $1.1 }
        guard w > 0 else { return nil }
        return Int((pts.reduce(0) { $0 + $1.0 * $1.1 } / w).rounded())
    }

    /// The factor most consistently off-target in the last 7 days — or nil if
    /// nothing is (we'd rather say nothing than invent a weakness).
    public static func focus(_ rs: [SessionRecord], now: Date = .now) -> Factor? {
        let week = rs.filter { $0.startedAt > now.addingTimeInterval(-7 * 86_400) }
        let fs = week.flatMap { r in r.scores.all.filter { $0.value != nil }.flatMap(\.factors).filter { !r.disputed.contains($0.id) } }
        let means = Dictionary(grouping: fs, by: \.id).mapValues { ($0[0], $0.map(\.penalty).reduce(0, +) / Double($0.count), $0.count) }
        return means.values.filter { $0.1 > 0.5 && $0.2 >= 2 }.max { $0.1 < $1.1 }?.0
    }

    public struct OutcomeLink: Equatable, Sendable {
        public var factorID: String
        public var label: String
        /// Correlation between this factor's penalty and your rating (negative
        /// = calls where you did better on it, you rated higher).
        public var r: Double
        public var n: Int
    }

    /// Outcome anchoring: which of *your* metrics track *your* own sense of
    /// how calls went. Needs ≥ 6 rated calls and |r| ≥ 0.35 to say anything.
    public static func whatPredictsGoodCalls(_ rs: [SessionRecord]) -> OutcomeLink? {
        let rated = rs.filter { $0.rating != nil && $0.scores.clarity.value != nil }
        guard rated.count >= 6 else { return nil }
        var byID: [String: (label: String, x: [Double], y: [Double])] = [:]
        for r in rated {
            for f in r.scores.all.flatMap(\.factors) where !r.disputed.contains(f.id) {
                byID[f.id, default: (f.label, [], [])].x.append(f.penalty)
                byID[f.id]!.y.append(r.rating!)
            }
        }
        return byID.compactMap { id, v in
            guard v.x.count >= 6, let r = Stats.pearson(v.x, v.y), r <= -0.35 else { return nil }
            return OutcomeLink(factorID: id, label: v.label, r: r, n: v.x.count)
        }.min { $0.r < $1.r }
    }
}
