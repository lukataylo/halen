import Accelerate
import Foundation

/// Per-frame acoustic features of the user's own voice. Frames are 10 ms hops
/// over 16 kHz mono audio, held in memory only for the session.
public struct Frame: Sendable, Equatable {
    /// Seconds from session start (frame centre).
    public var t: Double
    /// RMS level in dBFS.
    public var db: Float
    /// Fundamental frequency in Hz, or nil when unvoiced.
    public var f0: Float?
}

/// Streaming pitch + loudness extractor. Feed arbitrary-length chunks; it
/// keeps the tail it needs across calls so frames line up exactly.
///
/// Pitch is YIN (de Cheveigné & Kawahara 2002) with the cumulative-mean
/// normalised difference and parabolic interpolation. It is cheap (a few %
/// of one core at 100 frames/s) and good enough for the things we report —
/// range, variability, terminal rises — all of which are relative to the
/// user's own baseline, so absolute octave-error-free accuracy matters less
/// than consistency.
public struct ProsodyExtractor: Sendable {
    public static let sampleRate: Double = 16_000
    public static let hop = 160          // 10 ms
    public static let window = 1_024     // 64 ms — must be ≥ 2 × maxLag
    static let minF0: Double = 60
    static let maxF0: Double = 500
    static let yinThreshold: Float = 0.15
    /// Frames quieter than this are treated as silence and never pitched.
    public static let silenceDb: Float = -50

    private var buffer: [Float] = []
    private var consumed = 0            // samples dropped from the front of `buffer`

    public init() {}

    public mutating func process(_ samples: [Float]) -> [Frame] {
        buffer.append(contentsOf: samples)
        var frames: [Frame] = []
        var start = 0
        while start + Self.window <= buffer.count {
            let slice = Array(buffer[start ..< start + Self.window])
            let centre = Double(consumed + start + Self.window / 2) / Self.sampleRate
            let db = Self.rmsDb(slice)
            let f0 = db > Self.silenceDb ? Self.yin(slice) : nil
            frames.append(Frame(t: centre, db: db, f0: f0))
            start += Self.hop
        }
        if start > 0 {
            buffer.removeFirst(start)
            consumed += start
        }
        return frames
    }

    public static func rmsDb(_ x: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(x, 1, &rms, vDSP_Length(x.count))
        return 20 * log10(max(rms, 1e-7))
    }

    /// Returns F0 in Hz, or nil if no confident period was found.
    public static func yin(_ x: [Float]) -> Float? {
        let minLag = Int(sampleRate / maxF0)
        let maxLag = Int(sampleRate / minF0)
        let n = x.count - maxLag
        guard n > 0 else { return nil }

        // Difference function d(τ) = Σ (x[j] - x[j+τ])², computed with vDSP.
        var d = [Float](repeating: 0, count: maxLag + 1)
        var diff = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for lag in 1 ... maxLag {
                vDSP_vsub(p.baseAddress! + lag, 1, p.baseAddress!, 1, &diff, 1, vDSP_Length(n))
                var s: Float = 0
                vDSP_svesq(diff, 1, &s, vDSP_Length(n))
                d[lag] = s
            }
        }

        // Cumulative mean normalised difference.
        var cmnd = [Float](repeating: 1, count: maxLag + 1)
        var running: Float = 0
        for lag in 1 ... maxLag {
            running += d[lag]
            cmnd[lag] = running > 0 ? d[lag] * Float(lag) / running : 1
        }

        // First dip under threshold, then walk to its local minimum.
        var lag = minLag + 1
        while lag < maxLag {
            if cmnd[lag] < yinThreshold {
                while lag + 1 < maxLag && cmnd[lag + 1] < cmnd[lag] { lag += 1 }
                break
            }
            lag += 1
        }
        guard lag < maxLag, cmnd[lag] < yinThreshold else { return nil }

        // Parabolic interpolation for sub-sample precision — only valid at a
        // true local minimum, and never more than one sample of correction.
        let a = cmnd[lag - 1], b = cmnd[lag], c = cmnd[lag + 1]
        let denom = a - 2 * b + c
        let shift = (a > b && c >= b && denom > 0) ? min(max(0.5 * (a - c) / denom, -1), 1) : 0
        let f0 = Float(sampleRate) / (Float(lag) + shift)
        guard f0.isFinite, Double(f0) >= minF0 * 0.95, Double(f0) <= maxF0 * 1.05 else { return nil }
        return f0
    }
}

public enum Pitch {
    /// Semitones relative to 100 Hz — a perceptual scale, so variability is
    /// comparable between low and high voices.
    public static func semitones(_ hz: Float) -> Float { 12 * log2(hz / 100) }
}
