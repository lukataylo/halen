import AppKit
import SwiftUI
import Speech
import AVFoundation
import Carbon.HIToolbox

/// Global-hotkey-driven dictation. ⌥⌘Space toggles recording. While listening, a
/// floating indicator pulses near the caret. On stop, the transcription (local,
/// on-device via Apple's `SFSpeechRecognizer`) is inserted at the current caret
/// via the AX write-back path.
///
/// Why SFSpeechRecognizer instead of Gemma 4 audio: Apple's on-device recogniser
/// is purpose-built for this, runs offline on Apple Silicon, and ships with a
/// streaming API that takes raw audio buffers. Gemma 4 E2B technically supports
/// audio but Ollama's HTTP API doesn't expose audio input cleanly yet (May 2026).
@MainActor
final class VoiceDictation: HalenPlugin {
    let id = "com.halen.voice-dictation"
    let name = "Voice Dictation"
    let summary = "Press \u{2325}\u{2318}Space, speak, press again — text appears at your cursor."
    let icon = "mic.fill"
    let category: PluginCategory = .voice

    private let services: HalenServices
    private var eventTask: Task<Void, Never>?
    private let hotkey = HotkeyRegistrar()
    private var recorder: VoiceDictationRecorder?
    private var listeningPanel: NSPanel?

    private var lastCaretRect: CGRect?
    private var lastCaretOffset: Int = 0
    @ObservationIgnored private var isRecording = false
    private(set) var state = VoiceDictationState()

    init(services: HalenServices) {
        self.services = services
    }

    func start() {
        guard eventTask == nil else { return }
        registerHotkey()
        eventTask = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let p):
                    self.lastCaretRect = CGRect(x: p.rect.x, y: p.rect.y, width: p.rect.width, height: p.rect.height)
                case .textPaused(let p):
                    self.lastCaretOffset = p.caretOffset
                case .appFocused:
                    // Reset on app switch so we don't insert at a stale offset.
                    self.lastCaretOffset = 0
                default:
                    break
                }
            }
        }
        state.refreshPermissions()
        Log.info("VoiceDictation started (hotkey: \u{2325}\u{2318}Space)")
    }

    func stop() {
        unregisterHotkey()
        eventTask?.cancel()
        eventTask = nil
        if isRecording {
            finishRecording(commit: false)
        }
    }

    func makeDetailView() -> AnyView {
        AnyView(VoiceDictationDetailView(state: state))
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        let cmdOpt = UInt32(cmdKey | optionKey)
        let space = UInt32(kVK_Space)
        let ok = hotkey.register(keyCode: space, modifiers: cmdOpt) { [weak self] in
            self?.toggleRecording()
        }
        if !ok {
            Log.warn("VoiceDictation: failed to register ⌥⌘Space — another app may own it")
        }
    }

    private func unregisterHotkey() {
        hotkey.unregister()
    }

    // MARK: - Recording lifecycle

    private func toggleRecording() {
        if isRecording {
            finishRecording(commit: true)
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        state.refreshPermissions()

        let recorder = VoiceDictationRecorder()
        recorder.onTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.insertTranscript(text)
            }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                Log.warn("VoiceDictation: \(error.localizedDescription)")
                self?.state.engine = .idle
                self?.hideListeningIndicator()
                self?.isRecording = false
            }
        }
        recorder.onStateChange = { [weak self] engineState in
            Task { @MainActor [weak self] in
                self?.state.engine = engineState
            }
        }
        self.recorder = recorder
        isRecording = true
        state.engine = .listening
        showListeningIndicator()
        recorder.start()
    }

    private func finishRecording(commit: Bool) {
        guard isRecording else { return }
        isRecording = false
        recorder?.stop(commit: commit)
        if !commit {
            hideListeningIndicator()
        }
        // hideListeningIndicator gets called from insertTranscript on success
        // (after a small delay). On cancel, hide immediately.
    }

    private func insertTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            state.engine = .idle
            hideListeningIndicator()
            recorder = nil
        }
        guard !trimmed.isEmpty else {
            Log.info("VoiceDictation: empty transcript, nothing to insert")
            return
        }
        let range = NSRange(location: lastCaretOffset, length: 0)
        let payload = trimmed + " "
        services.caretObserver.replaceRange(range, with: payload)
        state.lastTranscript = trimmed
        Log.info("VoiceDictation inserted \(trimmed.count) chars at offset \(lastCaretOffset)")
    }

    // MARK: - Listening indicator

    private func showListeningIndicator() {
        if listeningPanel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VoiceListeningIndicator())

        let frame: NSRect
        if let caret = lastCaretRect, caret.width > 0 || caret.height > 0 {
            let x = max(20, caret.minX)
            let y = max(20, caret.minY - 70)
            frame = NSRect(x: x, y: y, width: 220, height: 52)
        } else if let screen = NSScreen.main {
            frame = NSRect(x: screen.frame.maxX - 240, y: 80, width: 220, height: 52)
        } else {
            frame = NSRect(x: 200, y: 200, width: 220, height: 52)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        listeningPanel = panel
    }

    private func hideListeningIndicator() {
        listeningPanel?.orderOut(nil)
        listeningPanel = nil
    }
}

// MARK: - Plugin state (observable so the detail view updates live)

@MainActor
@Observable
final class VoiceDictationState {
    enum Engine { case idle, listening, transcribing }

    var engine: Engine = .idle
    var micPermission: PermissionState = .notDetermined
    var speechPermission: PermissionState = .notDetermined
    var lastTranscript: String?

    func refreshPermissions() {
        micPermission = MicPermission.current
        speechPermission = SpeechPermission.current
    }
}

// MARK: - Permission helpers

enum PermissionState: Sendable {
    case notDetermined
    case granted
    case denied
}

enum MicPermission {
    static var current: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:      return .granted
        case .notDetermined:   return .notDetermined
        case .denied,
             .restricted:      return .denied
        @unknown default:      return .notDetermined
        }
    }
}

enum SpeechPermission {
    static var current: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        case .denied,
             .restricted:    return .denied
        @unknown default:    return .notDetermined
        }
    }
}
