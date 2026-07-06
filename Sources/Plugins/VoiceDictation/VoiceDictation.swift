import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import HalenPluginAPI

/// Global-hotkey-driven dictation. ⌃⌥Space toggles recording. While listening, a
/// floating indicator pulses near the caret. On stop, the transcription (local,
/// on-device via Apple's `SFSpeechRecognizer`) is inserted into the text field
/// that was focused when recording began, at the caret position captured then.
///
/// Why SFSpeechRecognizer instead of Gemma 4 audio: Apple's on-device recogniser
/// is purpose-built for this, runs offline on Apple Silicon, and ships with a
/// streaming API that takes raw audio buffers. Gemma 4 E2B technically supports
/// audio but Ollama's HTTP API doesn't expose audio input cleanly yet (May 2026).
@MainActor
public final class VoiceDictation: HalenPlugin {
    public static let pluginManifest = PluginManifest(
        id: "com.halen.voice-dictation", name: "Voice Dictation",
        summary: "Hold a hotkey, speak, get on-device text at your caret.",
        version: "0.4.0",
        events: ["caret.moved", "text.pause", "app.focused"],
        capabilities: [.observeText, .insertText, .hotkeys, .microphone,
                       .speechRecognition, .notifications, .popoverUI],
        icon: "mic.fill", category: .voice)

    public var manifest: PluginManifest { Self.pluginManifest }

    private let context: PluginContext
    private var eventTask: Task<Void, Never>?
    private var recorder: VoiceDictationRecorder?
    private var listeningPanel: NSPanel?

    private var lastCaretRect: CGRect?
    private var lastCaretOffset: Int = 0
    /// The field + caret captured at `beginRecording()`. The transcript callback
    /// fires seconds later, so we must write back to where recording *started*,
    /// not wherever focus happens to be when it finishes.
    private var capturedElement: AXUIElement?
    private var capturedOffset: Int = 0
    private var isRecording = false
    private(set) var state = VoiceDictationState()

    public init(context: PluginContext) {
        self.context = context
        state.permissions = context.permissions
    }

    public func start() {
        guard eventTask == nil else { return }
        registerHotkey()
        eventTask = Task { @MainActor [context, weak self] in
            for await event in context.events.subscribe() {
                guard let self else { return }
                switch event {
                case .caretMoved(let payload):
                    self.lastCaretRect = CGRect(x: payload.rect.x, y: payload.rect.y,
                                                width: payload.rect.width, height: payload.rect.height)
                case .textPaused(let payload):
                    self.lastCaretOffset = payload.caretOffset
                case .appFocused:
                    // Reset on app switch so we don't insert at a stale offset.
                    self.lastCaretOffset = 0
                default:
                    break
                }
            }
        }
        state.refreshPermissions()
        Log.info("VoiceDictation started (hotkey: \u{2303}\u{2325}Space)")
    }

    public func stop() {
        context.hotkeys?.unregisterAll()
        eventTask?.cancel()
        eventTask = nil
        if isRecording {
            finishRecording(commit: false)
        }
    }

    public func makeDetailView() -> AnyView {
        AnyView(VoiceDictationDetailView(state: state))
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        // ⌃⌥Space — two modifiers plus the space bar, easy to thumb-chord,
        // and nothing on a stock macOS install claims it. Earlier attempts
        // and why they failed:
        //   - ⌥⌘H: macOS reserves it for "Hide Others"; the menu-bar
        //     intercepts it before any global registration sees it.
        //   - ⌃G: every Cocoa Edit menu binds it for "Find Next"; the
        //     frontmost app's menu shortcut wins against our global
        //     registration whenever a Cocoa app is active.
        // ⌃⌥Space is in neither category — no Cocoa menu uses Control+
        // Option chords with Space, and Spotlight (⌘Space) / Raycast
        // (default ⌘Space) don't collide.
        let ok = context.hotkeys?.register(
            id: "toggle-dictation", keyCode: UInt32(kVK_Space),
            modifiers: [.control, .option]
        ) { [weak self] in
            self?.toggleRecording()
        } ?? false
        if !ok {
            // Either the chord was refused (another plugin or app owns it)
            // or the hotkeys grant was revoked — the host's conflict
            // registry surfaces both owners in Settings.
            Log.warn("VoiceDictation: failed to register ⌃⌥Space — see Settings → Conflicting hotkeys")
        }
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

        // Graceful denial: if either permission is `.denied`, don't even
        // start the recorder (it would fail silently inside AVAudioEngine).
        // Surface a toast and jump straight to the right System Settings
        // pane so the user has a path forward. Before this, ⌃⌥Space just
        // looked broken.
        if state.micPermission == .denied || state.speechPermission == .denied {
            notifyPermissionDenied()
            Log.warn("VoiceDictation: hotkey suppressed — mic=\(state.micPermission), speech=\(state.speechPermission)")
            return
        }
        state.resetLevels()

        // Capture the field + caret NOW — the transcript callback fires seconds
        // later, by which point focus or the caret may have moved.
        capturedElement = context.text?.focusedElement
        capturedOffset = capturedElement.flatMap { axReadSelectedRange($0)?.location } ?? lastCaretOffset

        let recorder = VoiceDictationRecorder()
        // The host brokers every TCC prompt — the recorder never calls
        // AVCaptureDevice/SFSpeechRecognizer request APIs itself.
        let permissions = context.permissions
        recorder.requestSpeechAuthorization = { @MainActor in
            await permissions.request(.speechRecognition)
        }
        recorder.requestMicAccess = { @MainActor in
            await permissions.request(.microphone)
        }
        recorder.onTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.insertTranscript(text)
            }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Log.warn("VoiceDictation: \(error.localizedDescription)")
                self.recorder?.stop(commit: false)
                self.recorder = nil
                self.state.engine = .idle
                self.hideListeningIndicator()
                self.isRecording = false
            }
        }
        recorder.onStateChange = { [weak self] engineState in
            Task { @MainActor [weak self] in
                self?.state.engine = engineState
            }
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.state.pushLevel(level)
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
            capturedElement = nil
        }
        guard !trimmed.isEmpty else {
            Log.info("VoiceDictation: empty transcript, nothing to insert")
            return
        }
        let range = NSRange(location: capturedOffset, length: 0)
        let payload = trimmed + " "
        // VoiceOver bridge — the dictation panel closes and text appears in
        // the field; VO users would otherwise hear nothing. `replaceRange`
        // posts at `.medium` (polite — doesn't interrupt VO mid-word); the
        // user explicitly stopped recording so they're already paying
        // attention, no need for `.high` here.
        let announcement = "Dictation inserted"
        let wrote: Bool
        if let element = capturedElement {
            wrote = context.text?.replaceRange(range, with: payload, in: element,
                                               describedAs: announcement) ?? false
        } else {
            wrote = context.text?.replaceRange(range, with: payload,
                                               describedAs: announcement) ?? false
        }
        state.lastTranscript = trimmed
        Log.info("VoiceDictation inserted \(trimmed.count) chars at offset \(capturedOffset) wrote=\(wrote)")
    }

    // MARK: - Permission denial fallback

    /// Posts a toast when ⌃⌥Space is pressed but Mic or Speech Recognition is
    /// denied, naming which permission needs flipping — then deep-links the
    /// exact Privacy & Security pane through the host's permission broker
    /// (most users won't see the toast if Notifications was never granted).
    private func notifyPermissionDenied() {
        let mic    = state.micPermission == .denied
        let speech = state.speechPermission == .denied
        let what: String
        switch (mic, speech) {
        case (true, true):   what = "Microphone and Speech Recognition access"
        case (true, false):  what = "Microphone access"
        case (false, true):  what = "Speech Recognition access"
        default:             return     // nothing to nag about
        }

        context.ui?.toast(
            title: "Voice Dictation needs permission",
            body: "Halen can't hear you — \(what) was denied. Flip it in System Settings.")
        // The deep link target is the privacy pane that actually contains
        // the toggle the user needs to flip.
        context.permissions.openSystemSettings(for: mic ? .microphone : .speechRecognition)
    }

    // MARK: - Listening indicator

    private func showListeningIndicator() {
        if listeningPanel != nil { return }
        // Panel is larger than the visible capsule on all sides — that
        // padding gives SwiftUI's soft drop shadow room to bloom inside
        // the rectangular panel bounds. Without it the shadow gets
        // clipped at the panel's hard corners and reads as a visible
        // rectangle around the capsule.
        let width: CGFloat = 388   // capsule 340 + 24 each side for shadow bleed
        let height: CGFloat = 100  // capsule 56  + 22 each side for shadow bleed
        // Listening pill — statusBar level (sits above floating popovers),
        // interactive (hosts Stop/Cancel buttons). Panel shadow OFF —
        // NSWindow's drop shadow tracks the panel's rectangular frame,
        // which would draw a visible rectangle around the capsule's
        // rounded corners. The SwiftUI view inside applies its own
        // shape-conforming shadow instead.
        let panel = HalenFloatingPanel.make(
            size: NSSize(width: width, height: height),
            level: .statusBar,
            interactive: true,
            shadow: false
        )
        panel.contentView = NSHostingView(
            rootView: VoiceListeningIndicator(
                state: state,
                onStop:   { [weak self] in self?.finishRecording(commit: true) },
                onCancel: { [weak self] in self?.finishRecording(commit: false) }
            )
        )

        let frame: NSRect
        if let caret = lastCaretRect, caret.width > 0 || caret.height > 0 {
            let x = max(20, caret.minX)
            let y = max(20, caret.minY - 70)
            frame = NSRect(x: x, y: y, width: width, height: height)
        } else if let screen = NSScreen.main {
            frame = NSRect(x: screen.frame.maxX - width - 20, y: 80, width: width, height: height)
        } else {
            frame = NSRect(x: 200, y: 200, width: width, height: height)
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
    var micPermission: PermissionGrant = .notRequested
    var speechPermission: PermissionGrant = .notRequested
    var lastTranscript: String?

    /// Host permission broker, injected by the plugin. Status reads and the
    /// System Settings deep link both go through it — the plugin never calls
    /// TCC APIs directly.
    @ObservationIgnored weak var permissions: (any PermissionService)?

    /// Rolling window of recent audio levels (0…1). Drives the live visualiser
    /// in the listening pill.
    static let levelHistorySize = 32
    var audioLevels: [Float] = Array(repeating: 0, count: 32)

    func pushLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        if audioLevels.count >= Self.levelHistorySize {
            audioLevels.removeFirst(audioLevels.count - Self.levelHistorySize + 1)
        }
        audioLevels.append(clamped)
    }

    func resetLevels() {
        audioLevels = Array(repeating: 0, count: Self.levelHistorySize)
    }

    func refreshPermissions() {
        micPermission = permissions?.status(of: .microphone) ?? .notRequested
        speechPermission = permissions?.status(of: .speechRecognition) ?? .notRequested
    }

    /// Open the Privacy & Security pane for `permission` — surfaced from the
    /// detail view's "Open Settings" affordance next to a denied row.
    func openSystemSettings(for permission: SystemPermission) {
        permissions?.openSystemSettings(for: permission)
    }
}
