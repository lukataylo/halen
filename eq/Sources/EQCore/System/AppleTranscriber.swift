@preconcurrency import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechAnalyzer (macOS 26+). Zero download beyond the
/// system language asset, word-level time ranges, runs on the ANE. Keeps
/// fillers (writes "uh" as "ah"); `FilledPauses` backs it up acoustically.
public final class AppleTranscriber: Transcriber, @unchecked Sendable {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<[Word], Error>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    public init(locale: Locale = .current) { self.locale = locale }

    public func start() async throws {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await req.downloadAndInstall()
        }
        let a = SpeechAnalyzer(modules: [t])
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) ?? MicCapture.format
        analyzerFormat = fmt
        if fmt != MicCapture.format { converter = AVAudioConverter(from: MicCapture.format, to: fmt) }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont
        analyzer = a

        collector = Task {
            var words: [Word] = []
            for try await result in t.results where result.isFinal {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    // A run can hold several words; spread its time evenly.
                    let parts = text.split(separator: " ")
                    let start = range.start.seconds, dur = range.duration.seconds / Double(parts.count)
                    for (i, p) in parts.enumerated() {
                        words.append(Word(text: String(p), start: start + Double(i) * dur, end: start + Double(i + 1) * dur))
                    }
                }
            }
            return words
        }
        do { try await a.start(inputSequence: stream) } catch {
            collector?.cancel(); collector = nil; input = nil
            throw error
        }
    }

    public func feed(_ samples: [Float]) async {
        guard let input, let buffer = makeBuffer(samples) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async throws -> [Word] {
        input?.finish()
        guard let collector else { return [] }
        // Never let a wedged analyzer hang the app in "analysing" forever.
        let analyzer = self.analyzer
        return try await withThrowingTaskGroup(of: [Word]?.self) { g in
            g.addTask { try await analyzer?.finalizeAndFinishThroughEndOfInput(); return try await collector.value }
            g.addTask { try await Task.sleep(for: .seconds(120)); return nil }
            let first = try await g.next() ?? nil
            g.cancelAll()
            if first == nil { collector.cancel() }
            return first ?? []
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let src = AVAudioPCMBuffer(pcmFormat: MicCapture.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter, let fmt = analyzerFormat else { return src }
        let cap = AVAudioFrameCount(Double(samples.count) * fmt.sampleRate / MicCapture.format.sampleRate) + 32
        guard let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        return err == nil ? dst : nil
    }
}
