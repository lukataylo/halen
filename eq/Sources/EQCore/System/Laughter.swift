@preconcurrency import AVFoundation
import Foundation
@preconcurrency import SoundAnalysis

/// Counts your laughs with Apple's built-in sound classifier (no download).
/// It only ever sees voice-checked audio, so it's your laughter, not theirs.
public final class LaughDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    private static let labels: Set<String> = ["laughter", "giggling", "chuckle_chortle", "belly_laugh", "snicker"]
    private let analyzer: SNAudioStreamAnalyzer
    private let queue = DispatchQueue(label: "dev.halen.eq.laughter")
    private var position: AVAudioFramePosition = 0
    private var inLaugh = false
    private var count = 0

    public init?(format: AVAudioFormat = MicCapture.format) {
        analyzer = SNAudioStreamAnalyzer(format: format)
        super.init()
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        guard (try? analyzer.add(request, withObserver: self)) != nil else { return nil }
    }

    public func feed(_ samples: [Float]) {
        guard let buf = AVAudioPCMBuffer(pcmFormat: MicCapture.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        queue.async { [self] in
            analyzer.analyze(buf, atAudioFramePosition: position)
            position += AVAudioFramePosition(samples.count)
        }
    }

    /// Number of distinct laughs (consecutive positive windows merge).
    public func finish() -> Int {
        queue.sync { analyzer.completeAnalysis() }
        return queue.sync { count }
    }

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let laughing = r.classifications.contains { Self.labels.contains($0.identifier) && $0.confidence > 0.5 }
        if laughing && !inLaugh { count += 1 }
        inLaugh = laughing
    }
}
