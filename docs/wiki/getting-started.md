# Getting started

## Prerequisites

- **macOS 14 Sonoma or newer.** Set via `LSMinimumSystemVersion` in
  `Resources/Info.plist`. The app uses `EKEventStore.requestFullAccessToEvents`,
  `requiresOnDeviceRecognition`, and other 14-only API.
- **Xcode command-line tools.** `xcode-select --install`.
- **Swift 5.10+** (ships with Xcode 15.3; Swift 6 also fine).
- **Ollama** running locally on the default port `11434`, with two models
  pulled:

  ```bash
  ollama pull gemma4:e2b   # used for small-tier (fast classification)
  ollama pull gemma4:e4b   # used for medium-tier (default for rewrites)
  ```

  Confirm with `ollama list` and a quick smoke test:

  ```bash
  curl -s http://localhost:11434/api/chat \
    -H 'Content-Type: application/json' \
    -d '{"model":"gemma4:e4b","stream":false,"messages":[{"role":"user","content":"say hi"}]}' \
    | jq -r '.message.content'
  ```

  The model→tier mapping is defined in
  [`OllamaInferenceClient.modelName(for:)`](../../Sources/Halen/Inference/OllamaInferenceClient.swift):
  `small → gemma4:e2b`, `medium → gemma4:e4b`, `large → gemma4:26b`.

## Build

Two scripts in [`scripts/`](../../scripts/):

```bash
./scripts/build-app.sh    # SPM build + assemble build/Halen.app + codesign
./scripts/run-dev.sh      # build, then launch the binary inside the bundle with stdout/stderr in your terminal
```

`build-app.sh` does:

1. `swift build -c debug` (override with `CONFIG=release`).
2. Copies the binary into `build/Halen.app/Contents/MacOS/halen`.
3. Copies `Resources/Info.plist` and the icon set into `Contents/Resources/`.
4. `codesign --force --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen`.

The default signing identity is a personal Apple Development cert; override
with `SIGN_IDENTITY=- ./scripts/build-app.sh` for ad-hoc signing. **Use the
same identity every rebuild** — the TCC database keys on the cert plus the
bundle id, and switching identities will re-prompt for every permission.

## Permissions

Halen needs five separate macOS permissions. Each one is the OS's standard
TCC prompt — Halen never asks for, sees, or stores credentials.

### 1. Accessibility (required, blocks everything else)

Used by `CaretObserver` to read text near the caret and write back
corrections via the AX API.

1. Launch the app once. It calls `AXIsProcessTrustedWithOptions(prompt:
   true)`, which triggers the "Halen would like to control your computer
   using Accessibility features" alert.
2. Open **System Settings → Privacy & Security → Accessibility**.
3. Click **+**, navigate to `build/Halen.app`, add it, then toggle it on.
4. `AppCoordinator` polls `AXIsProcessTrusted()` every second; once the
   toggle flips, the status bar in `HalenCenterView` updates from
   "Accessibility permission required" to "N of M plugins active" without
   needing a restart.

If you ever revoke and re-grant: do it from the same `build/Halen.app` path
so the TCC entry matches.

### 2. Microphone (Voice Dictation only)

Triggered the first time you press ⌥⌘Space.
`AVCaptureDevice.requestAccess(for: .audio)` shows the prompt.

Usage string (`NSMicrophoneUsageDescription` in `Info.plist`):

> Halen captures audio when you press ⌥⌘Space so it can transcribe your
> speech locally and insert it at your cursor. Audio never leaves this Mac.

### 3. Speech Recognition (Voice Dictation only)

Triggered alongside microphone access.
`SFSpeechRecognizer.requestAuthorization` shows the prompt.

Usage string (`NSSpeechRecognitionUsageDescription`):

> Halen uses Apple's on-device speech recognition to convert your
> dictation to text. Recognition is offline; nothing is sent to the cloud.

`VoiceDictationRecorder` sets `requiresOnDeviceRecognition = true`. On a
fresh macOS install you may need to download the on-device speech model for
your locale (System Settings → Keyboard → Dictation → Languages — toggle a
language and tick "Enhanced"). Until then the recogniser reports unavailable
and dictation logs `Speech recogniser is unavailable (no on-device model?)`.

### 4. Calendar (Burnout Copilot + Meeting Prep)

Triggered when either plugin starts.
`EKEventStore.requestFullAccessToEvents()` on macOS 14+.

Usage strings (`NSCalendarsUsageDescription`, `NSCalendarsFullAccessUsageDescription`):

> Halen reads your upcoming events to suggest breaks (Burnout Copilot) and
> prepare briefings before meetings (Meeting Prep). Calendar data is read
> locally only.

Burnout Copilot also writes a single 10-minute "🌿 Halen break" event when
you accept its suggestion — that requires the full-access scope.

### 5. Notifications (Meeting Prep only)

`UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])`.
Meeting Prep posts one notification 1 second after a briefing lands on your
clipboard. If you deny, the clipboard part still works.

## Where data lives

```
~/Library/Application Support/Halen/
  typos.json                                  # personal typo dictionary
  com.halen.sentiment-guard/
    rules.json                                # tone-detection rules
    approved.json                             # SHA-256 fingerprints of approved drafts
  com.halen.snippet-expander/
    snippets.json                             # snippets
  com.halen.meeting-prep/
    processed.json                            # event identifiers already briefed
```

All hand-editable JSON. The host merges built-in seeds on every launch
without overwriting user changes — see each plugin's "Storage" section.

## Common issues

| Symptom | Likely cause |
|---|---|
| Menubar says "Accessibility permission required" | App is signed by a different identity than the TCC entry. Re-add `build/Halen.app` to System Settings. |
| ⌥⌘Space does nothing | Another app owns the shortcut. Logs show `HotkeyRegistrar: RegisterEventHotKey failed`. |
| Typo Fixer never fires | Focused text field is non-AX (Electron / web / terminal). Logs show `replaceRange: failed to set selection range`. |
| Sentiment Guard never fires | Ollama not running, or `gemma4:e4b` not pulled. Check `curl http://localhost:11434/api/tags`. |
| Voice Dictation says "recogniser unavailable" | On-device speech model not installed. System Settings → Keyboard → Dictation. |
| Meeting Prep never fires | Calendar access denied, or no event 13–17 min away. Use the "Generate now" button in the plugin detail view. |
