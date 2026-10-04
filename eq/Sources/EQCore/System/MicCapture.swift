@preconcurrency import AVFoundation
import Foundation

/// Microphone only — never system audio. Converts whatever the input device
/// gives us to 16 kHz mono float and hands it off in ~100 ms chunks.
public final class MicCapture: @unchecked Sendable {
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private let lock = NSLock()
    private var _origin: Double?
    private var _level: Float = -120

    /// Host time (seconds) of the first captured sample — the session clock's zero.
    public var origin: Double? { lock.withLock { _origin } }
    /// Latest mic level in dBFS, for the live meter.
    public var currentLevel: Float { lock.withLock { _level } }

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Chunks arrive in capture order on a single stream; the stream ends
    /// when `stop()` is called. (One Task per buffer would let chunks race.)
    public func start() throws -> AsyncStream<[Float]> {
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        do { try installTapAndStart() } catch { cont.finish(); throw error }
        // Joining a call often flips a Bluetooth headset to HFP, changing the
        // input format; AVAudioEngine stops itself. Re-tap on the new format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self, self.continuation != nil else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            if (try? self.installTapAndStart()) == nil { self.stop() }
        }
        return stream
    }

    private var configObserver: NSObjectProtocol?

    public enum CaptureError: Error { case noInputDevice }

    private func installTapAndStart() throws {
        guard let cont = continuation else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw CaptureError.noInputDevice }
        converter = AVAudioConverter(from: inFormat, to: Self.format)
        let ratio = Self.format.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 10), format: inFormat) { [weak self] buffer, when in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let ch = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.lock.withLock {
                if self._origin == nil, when.isHostTimeValid { self._origin = HostTime.seconds(when.hostTime) }
                self._level = ProsodyExtractor.rmsDb(samples)
            }
            cont.yield(samples)
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    public func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
