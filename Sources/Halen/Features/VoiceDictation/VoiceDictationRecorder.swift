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

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var bestTranscript: String = ""

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
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
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
                        self.onTranscript?(self.bestTranscript)
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
    func stop(commit: Bool) {
        cleanupAudio()
        if commit {
            request?.endAudio()
            // If there's a partial we never get a final for (rare), emit what we have.
            if recognitionTask?.state != .running {
                if !bestTranscript.isEmpty {
                    onTranscript?(bestTranscript)
                }
            }
        } else {
            recognitionTask?.cancel()
        }
        request = nil
    }

    private func cleanupAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}

enum VoiceDictationError: LocalizedError {
    case speechNotAuthorised
    case micNotAuthorised
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorised:    return "Speech recognition is not authorised."
        case .micNotAuthorised:       return "Microphone access is not authorised."
        case .recognizerUnavailable:  return "Speech recogniser is unavailable (no on-device model?)"
        }
    }
}
