# Getting started

## Prerequisites

- **macOS 14 Sonoma or newer.** Set via `LSMinimumSystemVersion` in
  `Resources/Info.plist`. The app uses `EKEventStore.requestFullAccessToEvents`,
  `requiresOnDeviceRecognition`, and other 14-only API.
- **Xcode command-line tools.** `xcode-select --install`.
- **Swift 5.10+** (ships with Xcode 15.3; Swift 6 also fine).
- **An inference backend.** `RouterInferenceClient` routes across whatever is
  available, so you need at least one of:

  - **Apple Intelligence** (macOS 26+) — nothing to install or configure.
  - The **bundled Gemma 4 E4B model** — fetched on first use by the in-app
    `ModelDownloader` (Settings → Inference), or baked into the `.app` with a
    `BUNDLE_MODEL=1` build.
  - **Ollama** running locally on the default port `11434`. Pull the models
    matching the tiers you want:

    ```bash
    ollama pull gemma4:e2b   # small-tier (fast classification)
    ollama pull gemma4:e4b   # medium-tier (default for rewrites)
    ollama pull gemma4:26b   # large-tier (optional, heavy reasoning)
    ```

    Confirm with `ollama list` and a quick smoke test:

    ```bash
    curl -s http://localhost:11434/api/chat \
      -H 'Content-Type: application/json' \
      -d '{"model":"gemma4:e4b","stream":false,"messages":[{"role":"user","content":"say hi"}]}' \
      | jq -r '.message.content'
    ```

  The Ollama model→tier mapping is defined in
  [`OllamaInferenceClient.modelName(for:)`](../../Sources/Halen/Inference/OllamaInferenceClient.swift):
  `small → gemma4:e2b`, `medium → gemma4:e4b`, `large → gemma4:26b`. Backend
  order is configurable in Settings → Inference.

## Build

Scripts in [`scripts/`](../../scripts/):

```bash
./scripts/build-app.sh    # SPM build + assemble build/Halen.app + codesign
./scripts/run-dev.sh      # build-app.sh, then quit-old / launch / stream the log
./scripts/fetch-assets.sh # fetch the vendored llama.xcframework + GGUF (BUNDLE_MODEL builds)
./scripts/notarize.sh     # notarize + staple a DIST build
```

`build-app.sh` does:

1. `swift build -c debug` (override with `CONFIG=release`; `DIST=1` forces a
   release build).
2. Copies the binary into `build/Halen.app/Contents/MacOS/halen`.
3. Copies `Resources/Info.plist` and the icon set into `Contents/Resources/`.
4. Embeds `llama.framework` (from `Vendor/llama.xcframework`) into
   `Contents/Frameworks/` and patches the binary's rpath.
5. Optionally bundles the Gemma 4 GGUF when `BUNDLE_MODEL=1` (default: slim
   build, the in-app `ModelDownloader` fetches the model on first use).
6. Signs nested code then the app:
   `codesign --force --sign "$SIGN_IDENTITY" --identifier com.dadiani.halen`.

The default dev signing identity is a personal Apple Development cert; override
with `SIGN_IDENTITY=- ./scripts/build-app.sh` for ad-hoc signing. **Use the
same identity every rebuild** — the TCC database keys on the cert plus the
bundle id, and switching identities will re-prompt for every permission.

A `DIST=1 ./scripts/build-app.sh` produces a notarization-ready build (release
config, Developer ID signing, Hardened Runtime, secure timestamp,
entitlements); follow it with `./scripts/notarize.sh`. On a fresh checkout,
`fetch-assets.sh` first builds `Vendor/llama.xcframework` from the pinned
llama.cpp tag (`SKIP_GGUF=1` skips the multi-GB model download).

## Permissions

Halen uses up to six separate macOS permissions. Each one is the OS's standard
TCC prompt — Halen never asks for, sees, or stores credentials. Only
Accessibility is required; the rest gate individual plugins.

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

Triggered the first time you press ⌥⌘H.
`AVCaptureDevice.requestAccess(for: .audio)` shows the prompt.

Usage string (`NSMicrophoneUsageDescription` in `Info.plist`):

> Halen captures audio when you press ⌥⌘H so it can transcribe your
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

### 6. Input Monitoring (Ask Halen + Snippet Expander rephrase)

Ask Halen's ⌃H palette and Snippet Expander's ⌃⌥R rephrase-selection hotkey
use `NSEvent` global monitors, which need Input Monitoring to fire while
another app is frontmost. Halen calls `IOHIDRequestAccess` on launch.

Usage string (`NSInputMonitoringUsageDescription`):

> Halen listens for the ⌃H hotkey so the Ask Halen palette can open in any
> app. Only the hotkey is matched; no other keystrokes are recorded.

If you deny it, the hotkeys still fire while Halen itself is frontmost. Grant
it under **System Settings → Privacy & Security → Input Monitoring** for
system-wide use. (Voice Dictation's ⌥⌘H uses Carbon `RegisterEventHotKey`
instead and needs no permission beyond Accessibility.)

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
| Any permission stuck — granted but not working, and System Settings won't let you toggle it | The code signature changed (ad-hoc / failed `codesign` / new identity) and TCC's grant is orphaned on the old signature. Run `scripts/reset-permissions.sh` (`tccutil reset` for every service Halen uses), then relaunch and re-grant. |
| ⌥⌘H does nothing | Another app owns the shortcut. Logs show `HotkeyRegistrar: RegisterEventHotKey failed`. |
| ⌃H / ⌃⌥R fire only when Halen is frontmost | Input Monitoring not granted. Add Halen under System Settings → Privacy & Security → Input Monitoring. (⌃H is also consumed as backspace inside Terminal / iTerm by design.) |
| Typo Fixer never fires | Focused text field is non-AX (Electron / web / terminal). Logs show `replaceRange: failed to set selection range`. |
| Sentiment Guard never fires | No inference backend available. Check Settings → Inference for backend status; if relying on Ollama, confirm it's running with `curl http://localhost:11434/api/tags`. |
| Voice Dictation says "recogniser unavailable" | On-device speech model not installed. System Settings → Keyboard → Dictation. |
| Meeting Prep never fires | Calendar access denied, or no event 13–17 min away. Use the "Generate now" button in the plugin detail view. |
