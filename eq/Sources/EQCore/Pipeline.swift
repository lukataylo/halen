import Foundation

/// Streaming speech-to-text over the *voice-checked* audio. Rejected windows
/// arrive as silence so word timestamps stay on the session clock.
public protocol Transcriber: AnyObject, Sendable {
    func start() async throws
    func feed(_ samples: [Float]) async
    func finish() async throws -> [Word]
}

/// The per-session pipeline. Audio enters, is voice-checked, turned into
/// frames, words and laugh counts, and is never written to disk.
public actor SessionPipeline {
    private let voiceCheck: VoiceCheck?
    private let transcriber: Transcriber?
    private let laughs = LaughDetector()
    private var prosody = ProsodyExtractor()
    private var pending: [Float] = []
    private var frames: [Frame] = []
    private var samplesSeen = 0
    private var ignored = 0

    /// `voiceCheck` nil (or without a voice print) = keep everything.
    public init(voiceCheck: VoiceCheck?, transcriber: Transcriber?) {
        self.voiceCheck = voiceCheck
        self.transcriber = transcriber
    }

    public func start() async throws { try await transcriber?.start() }

    /// 16 kHz mono float samples, any chunk size. Callers must ingest in
    /// order from a single task (see `MicCapture.start()`).
    public func ingest(_ samples: [Float]) async {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= VoiceCheck.window {
            await process(Array(pending[offset ..< offset + VoiceCheck.window]))
            offset += VoiceCheck.window
        }
        pending.removeFirst(offset)
    }

    private func process(_ input: [Float]) async {
        var window = input
        if let voiceCheck, await voiceCheck.print != nil {
            // Near-silent windows skip the speaker check but are zeroed, not
            // passed through: a quiet "yeah" from someone else is still not you.
            let quiet = ProsodyExtractor.rmsDb(window) <= ProsodyExtractor.silenceDb
            let mine = quiet ? false : await voiceCheck.isUser(window)
            if !mine {
                if !quiet { ignored += window.count }
                window = [Float](repeating: 0, count: window.count)
            }
        }
        samplesSeen += window.count
        frames.append(contentsOf: prosody.process(window))
        laughs?.feed(window)
        await transcriber?.feed(window)
    }

    /// `other`: far-end speech spans from `FarEndTap`, if it ran.
    public func finish(other: [Span]?) async throws -> (SessionMetrics, [Word]) {
        if !pending.isEmpty { let tail = pending; pending = []; await process(tail) }
        let words = try await transcriber?.finish() ?? []
        var m = MetricsBuilder.build(frames: frames, words: words, other: other,
                                     duration: Double(samplesSeen) / ProsodyExtractor.sampleRate)
        m.laughs = laughs?.finish() ?? 0
        m.ignoredSeconds = Double(ignored) / ProsodyExtractor.sampleRate
        m.voiceChecked = await voiceCheck?.print != nil
        return (m, words)
    }
}
