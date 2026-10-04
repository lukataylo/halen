import Foundation

/// A half-open time interval in session seconds.
public struct Span: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
    public func overlaps(_ o: Span) -> Bool { start < o.end && o.start < end }
}

public enum Activity {
    /// Speech spans from frame loudness, with an adaptive noise floor and
    /// hysteresis. This is a level-based detector — the neural VAD + voice
    /// gate decide *whose* speech it is upstream; by the time frames arrive
    /// here, non-user audio has already been zeroed.
    public static func speechSpans(
        _ frames: [Frame],
        mergeGap: Double = 0.25,
        minDuration: Double = 0.15
    ) -> [Span] {
        guard !frames.isEmpty else { return [] }
        // Ignore digital silence (gated-out windows are zeroed) when finding
        // the room's noise floor, or the floor collapses to -140 dB.
        let sorted = frames.map(\.db).filter { $0 > -100 }.sorted()
        guard !sorted.isEmpty else { return [] }
        let floor = sorted[sorted.count / 10]
        // With a very quiet mic (or everything but your voice gated out) the
        // "floor" can be speech itself, so also cap 10 dB under the loud end.
        let loud = sorted[sorted.count * 9 / 10]
        let threshold = max(min(floor + 12, loud - 10), ProsodyExtractor.silenceDb)

        var spans: [Span] = []
        var open: Double?
        let half = Double(ProsodyExtractor.hop) / ProsodyExtractor.sampleRate / 2
        for f in frames {
            let active = f.db > threshold
            if active, open == nil { open = f.t - half }
            if !active, let s = open { spans.append(Span(s, f.t - half)); open = nil }
        }
        if let s = open { spans.append(Span(s, frames.last!.t + half)) }
        return merge(spans, gap: mergeGap).filter { $0.duration >= minDuration }
    }

    public static func merge(_ spans: [Span], gap: Double) -> [Span] {
        var out: [Span] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start - last.end <= gap {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Own "turns": speech spans joined across short pauses, but split
    /// wherever the other party spoke in between.
    public static func turns(own: [Span], other: [Span]?, joinGap: Double = 1.2) -> [Span] {
        var out: [Span] = []
        for s in own {
            if let last = out.last, s.start - last.end <= joinGap {
                let gap = Span(last.end, s.start)
                let otherSpoke = other?.contains { $0.overlaps(gap) && $0.duration > 0.4 } ?? false
                if !otherSpoke { out[out.count - 1].end = s.end; continue }
            }
            out.append(s)
        }
        return out
    }
}
