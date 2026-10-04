import FluidAudio
import Foundation

/// "Is this me?" — WeSpeaker speaker embeddings (FluidAudio, CoreML/ANE)
/// compared with your enrolled voice print. Windows that aren't you are
/// zeroed in memory before anything else sees them.
public actor VoiceCheck {
    public static let window = 24_000          // 1.5 s at 16 kHz — the gate's unit

    private let diarizer: DiarizerManager
    public private(set) var print: VoicePrint?

    private init(diarizer: DiarizerManager, print: VoicePrint?) {
        self.diarizer = diarizer
        self.print = print
    }

    /// Loads (first run: downloads, ~30 MB) the embedding model.
    public static func load(print: VoicePrint?) async throws -> VoiceCheck {
        let models = try await DiarizerModels.downloadIfNeeded()
        let d = DiarizerManager()
        d.initialize(models: models)
        return VoiceCheck(diarizer: d, print: print)
    }

    /// Fails closed: if there's a voice print and the check can't run, the
    /// window is treated as *not* you and dropped.
    public func isUser(_ window: [Float]) -> Bool {
        guard let print else { return true }
        guard let e = try? diarizer.extractSpeakerEmbedding(from: window) else { return false }
        return Self.cosine(e, print.centroid) >= print.threshold
    }

    /// Build a voice print from ~30 s of you reading aloud. The threshold is
    /// learned from how similar your *own* 1.5 s windows are to your centroid
    /// (mean − 3 sd), so it adapts to your mic and voice rather than a magic
    /// constant.
    public func enroll(_ samples: [Float]) throws -> VoicePrint {
        let windows = stride(from: 0, to: samples.count - Self.window, by: Self.window / 2)
            .map { Array(samples[$0 ..< $0 + Self.window]) }
            .filter { ProsodyExtractor.rmsDb($0) > ProsodyExtractor.silenceDb + 10 }
        guard windows.count >= 8 else { throw EnrollmentError.notEnoughSpeech }
        let embs = try windows.map { try diarizer.extractSpeakerEmbedding(from: $0) }
        let centroid = Self.normalize(embs.reduce([Float](repeating: 0, count: embs[0].count)) { zip($0, $1).map(+) })
        let sims = embs.map { Double(Self.cosine($0, centroid)) }
        let threshold = Float(min(max(Stats.mean(sims) - 3 * Stats.sd(sims), 0.3), 0.6))
        let p = VoicePrint(centroid: centroid, threshold: threshold, created: .now)
        print = p
        return p
    }

    public enum EnrollmentError: LocalizedError {
        case notEnoughSpeech
        public var errorDescription: String? { "Didn't hear enough speech — read the passage aloud at your normal volume." }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
