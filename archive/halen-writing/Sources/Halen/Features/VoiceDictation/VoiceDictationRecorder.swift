import AVFoundation
import Speech
import Foundation

/// Wraps AVAudioEngine + SFSpeechRecognizer for one-shot dictation. Streams audio
/// buffers from the input node into a `SFSpeechAudioBufferRecognitionRequest`; on
/// `stop(commit: true)` emits the final transcript via `onTranscript`.
///
/// `requiresOnDeviceRecognition = true` keeps recognition strictly local. Requires
/// the user to have the on-device model downloaded for their locale (default on
/// modern macOS).
final class VoiceDictationRecorder {
    var onTranscript: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onStateChange: ((VoiceDictationState.Engine) -> Void)?
    /// Emits a normalised 0…1 audio level every audio-buffer tick (~20 Hz).
    var onLevel: ((Float) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var bestTranscript: String = ""
    /// Latch so the final transcript is emitted at most once — `stop()`'s
    /// fallback and the recogniser's `isFinal` callback can otherwise both fire.
    private var hasDelivered = false

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.onError?(VoiceDictationError.speechNotAuthorised)
                    return
                }
                self.requestMicAndBegin()
            }
        }
    }

    private func requestMicAndBegin() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.onError?(VoiceDictationError.micNotAuthorised)
                    return
                }
                self.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            onError?(VoiceDictationError.recognizerUnavailable)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // `installTap` with a 0-channel / 0-sample-rate format (no input device,
        // or the device hasn't spun up yet right after a permission grant)
        // throws an uncatchable Objective-C exception — guard it as a Swift error.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            onError?(VoiceDictationError.noAudioInput)
            return
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req, weak self] buffer, _ in
            req?.append(buffer)
            self?.emitLevel(from: buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cleanupAudio()
            onError?(error)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.bestTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.deliver(self.bestTranscript)
                    }
                }
            }
            if let error {
                // Cancellation comes through as an error too — only surface real failures.
                let nsError = error as NSError
                if nsError.code != 301 && nsError.code != 216 {
                    DispatchQueue.main.async {
                        self.onError?(error)
                    }
                }
            }
        }
    }

    /// Stop capture. If `commit`, ends the audio stream so the recogniser emits a
    /// final transcript (`onTranscript` will be called). If not, just tears down.
    /// Must be called on the main queue.
    func stop(commit: Bool) {
        cleanupAudio()
        if commit {
            onStateChange?(.transcribing)
            request?.endAudio()
            // If there's a partial we never get a final for (rare), emit what we
            // have. `deliver`'s latch keeps this from double-firing with `isFinal`.
            if recognitionTask?.state != .running, !bestTranscript.isEmpty {
                deliver(bestTranscript)
            }
        } else {
            recognitionTask?.cancel()
        }
        request = nil
    }

    /// Emit the final transcript at most once. Both call sites run on the main
    /// queue, so the `hasDelivered` latch needs no further synchronisation.
    private func deliver(_ transcript: String) {
        guard !hasDelivered else { return }
        hasDelivered = true
        onTranscript?(transcript)
    }

    private func cleanupAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Compute RMS amplitude of the buffer, convert to a normalised 0…1 level
    /// (dB-scaled so quiet rooms register as low but speech registers high).
    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?.pointee else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sumSquares: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        // RMS is typically tiny; convert to dB and normalise -60 → 0 dB to 0 → 1.
        let db = 20 * log10(max(0.0001, rms))
        let normalised = max(0, min(1, (db + 60) / 60))

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(normalised)
        }
    }
}

enum VoiceDictationError: LocalizedError {
    case speechNotAuthorised
    case micNotAuthorised
    case recognizerUnavailable
    case noAudioInput

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorised:    return "Speech recognition is not authorised."
        case .micNotAuthorised:       return "Microphone access is not authorised."
        case .recognizerUnavailable:  return "Speech recogniser is unavailable (no on-device model?)"
        case .noAudioInput:           return "No microphone input device is available."
        }
    }
}
