@preconcurrency import AVFoundation
import EQCore
import Foundation

/// Dev tool: run the full pipeline over an audio file and print the metrics,
/// scores, and detected filler spans. Nothing is written anywhere.
///
///     swift run eq-analyze path/to/clip.m4a [--no-asr]
@main
struct EQAnalyze {
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            print("usage: eq-analyze <audio file> [--no-asr]"); exit(2)
        }
        let samples = try load(URL(fileURLWithPath: path))
        let transcriber: Transcriber? = args.contains("--no-asr") ? nil : AppleTranscriber(locale: Locale(identifier: "en-US"))
        let pipeline = SessionPipeline(voiceCheck: nil, transcriber: transcriber)
        try await pipeline.start()
        for chunk in stride(from: 0, to: samples.count, by: 1_600) {
            await pipeline.ingest(Array(samples[chunk ..< min(chunk + 1_600, samples.count)]))
        }
        let (m, words) = try await pipeline.finish(other: nil)

        print("Transcript: " + words.map(\.text).joined(separator: " "))
        let card = ScoreCard(metrics: m, baseline: Baseline())
        for (name, s) in [("Presence", card.presence), ("Clarity", card.clarity), ("Composure", card.composure)] {
            print("\n\(name) \(s.value.map(String.init) ?? "–")")
            for f in s.factors { print(String(format: "  %-16@ %-28@ penalty %.2f", f.label as NSString, f.detail as NSString, f.penalty)) }
        }
        var copy = m; copy.windows = []
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("\nMetrics:\n" + String(data: try enc.encode(copy), encoding: .utf8)!)
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let conv = AVAudioConverter(from: inFmt, to: MicCapture.format)!
        let out = AVAudioPCMBuffer(pcmFormat: MicCapture.format,
                                   frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16_000 / inFmt.sampleRate) + 1_024)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return buf
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
