# Voice Dictation

> Plugin id: `com.halen.voice-dictation` · Category: Voice · Code:
> [`Sources/Halen/Features/VoiceDictation/`](../../../Sources/Halen/Features/VoiceDictation/)

Press **⌥⌘Space**, speak, press again — the transcription appears at your
cursor. Apple's on-device recogniser does the speech-to-text; nothing
hits the network.

## Hotkey: Carbon `RegisterEventHotKey`

Defined in
[`HotkeyRegistrar.swift`](../../../Sources/Halen/Features/VoiceDictation/HotkeyRegistrar.swift).

Why Carbon instead of `NSEvent.addGlobalMonitorForEvents`: the NSEvent
global-monitor path didn't fire reliably for ⌥⌘Space (it conflicts with
the system dictation shortcut at the event-tap level), and it needs Input
Monitoring permission. Carbon's `RegisterEventHotKey` is the canonical
mechanism for menubar apps that need a real, system-wide shortcut and
works without any additional TCC prompt beyond Accessibility.

The signature `'HALN'` (`0x48414c4e`) is used as the `EventHotKeyID`.

```swift
let cmdOpt = UInt32(cmdKey | optionKey)
let space = UInt32(kVK_Space)
hotkey.register(keyCode: space, modifiers: cmdOpt) { [weak self] in
    self?.toggleRecording()
}
```

`HotkeyRegistrar` installs an `EventHandlerUPP` on
`GetApplicationEventTarget()` and hands the callback's `userData` pointer
back to a Swift closure on the main queue. On failure
(another app owns the shortcut), it logs and returns false silently.

## Recorder: AVAudioEngine + SFSpeechRecognizer

Defined in
[`VoiceDictationRecorder.swift`](../../../Sources/Halen/Features/VoiceDictation/VoiceDictationRecorder.swift).

```swift
let req = SFSpeechAudioBufferRecognitionRequest()
req.shouldReportPartialResults = true
if #available(macOS 13.0, *) {
    req.requiresOnDeviceRecognition = true
}
```

- **Audio**: `AVAudioEngine.inputNode` with a 1024-frame tap that appends
  every buffer to the recognition request and computes the buffer's RMS
  amplitude for the visualiser (see below).
- **Recognition**: `SFSpeechRecognizer().recognitionTask(with: req)`.
  `requiresOnDeviceRecognition = true` is the line that keeps audio off
  Apple's servers. On macOS 14+ this is the default for Apple Silicon
  Macs that have the on-device model installed, but Halen makes it
  explicit so a missing model fails loudly (`recognizerUnavailable`)
  instead of silently round-tripping audio to the cloud.

Errors with NSError codes `301` and `216` (cancellation and benign
end-of-audio) are filtered out so the UI doesn't flash an error when the
user just presses ⌥⌘Space again to stop.

## Permission flow

`VoiceDictationRecorder.start()` chains the two prompts:

1. `SFSpeechRecognizer.requestAuthorization { status in ... }`
2. Then, on success, `AVCaptureDevice.requestAccess(for: .audio)`

Both states are also surfaced as `MicPermission.current` and
`SpeechPermission.current` enums for the detail view, so the user can see
whether each is `granted` / `denied` / `notDetermined`.

`Info.plist` strings:

- `NSMicrophoneUsageDescription`:
  > Halen captures audio when you press ⌥⌘Space so it can transcribe your
  > speech locally and insert it at your cursor. Audio never leaves this Mac.
- `NSSpeechRecognitionUsageDescription`:
  > Halen uses Apple's on-device speech recognition to convert your
  > dictation to text. Recognition is offline; nothing is sent to the cloud.

## The listening pill

A floating `NSPanel` (300 × 52, `.statusBar` level, non-activating,
borderless) opens when recording starts. Anchored above the caret if
`caret.moved` has fired recently — Voice Dictation tracks the last
`caretMoved` rect from the event bus and re-uses it to position the pill.
Fallback: bottom-right of the main screen.

`VoiceListeningIndicator` (a SwiftUI view) shows:

- A pulsing mic glyph
- A live audio-level visualiser driven by a rolling window of 32 RMS
  samples (`VoiceDictationState.audioLevels`)
- "Stop" and "Cancel" buttons that commit / abort the recognition

### Audio level computation

In `emitLevel(from buffer:)`:

```swift
let rms = sqrt(sumSquares / Float(frameLength))
let db = 20 * log10(max(0.0001, rms))
let normalised = max(0, min(1, (db + 60) / 60))
```

RMS → dB → linear-normalised −60…0 dB range. Quiet rooms show a low
baseline, normal speech maxes out the bar.

## AX write-back at the caret

`VoiceDictation` subscribes to the event bus so it always has the latest
caret offset and rect:

```swift
case .caretMoved(let p):
    self.lastCaretRect = CGRect(...)
case .textPaused(let p):
    self.lastCaretOffset = p.caretOffset
case .appFocused:
    self.lastCaretOffset = 0   // reset on app switch
```

When `insertTranscript(_:)` runs after a successful recognition:

```swift
let range = NSRange(location: lastCaretOffset, length: 0)
let payload = trimmed + " "
services.caretObserver.replaceRange(range, with: payload)
```

Zero-length range = insertion. Trailing space mirrors how Apple's own
dictation behaves so the next word doesn't need a manual space. The same
constraint as TypoFixer / SnippetExpander applies: the focused field must
honour AX writes (most native AppKit text fields do; most
Electron / web / terminal fields don't).

## Listening state

`VoiceDictationState` (`@Observable`) drives the detail view:

```swift
enum Engine { case idle, listening, transcribing }
var engine: Engine
var micPermission: PermissionState
var speechPermission: PermissionState
var lastTranscript: String?
var audioLevels: [Float]   // 32-sample rolling window
```

The detail view shows the engine state, permission summary, and the last
transcript so the user can confirm what was inserted without having to
look at the inserted text in the host app.
