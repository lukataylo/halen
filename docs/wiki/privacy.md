# Privacy

One constraint. Nothing leaves the machine.

Not the text near your cursor. Not your drafts. Not your voice.
Not a hashed fingerprint of any of it. Not an anonymous telemetry
ping. Nothing.

The few egress points that do exist all hit localhost — the local
inference backend you chose, or your local Ollama daemon if you
opted in. This page documents every one of them, the per-plugin
boundaries, and the on-disk files Halen writes.

## What Halen sees

Once Accessibility is granted, the `CaretObserver`
(`Sources/Halen/Accessibility/CaretObserver.swift`) reads two AX
attributes from whichever text field is currently focused, system-wide:

- `kAXValueAttribute` — the full text of the field.
- `kAXSelectedTextRangeAttribute` — the caret offset (and selection if any).

That includes any text you're editing in any app that exposes a native AX
text element: Mail compose windows, Notes, Slack, Notion, Apple Calendar
event titles, browser address bars, IDE editor panes, and so on. **It
does not include the screen pixel buffer, the keyboard event stream,
window titles, file system contents, or anything outside the focused
field.**

Payloads are **windowed to 8 000 characters around the caret** before
being published to the event bus:

```swift
let (text, caretOffset) = windowAroundCaret(text: fullText, offset: fullOffset, radius: 4000)
```

That cap exists so a terminal scrollback or a long Notes document can't
blast inference plugins with megabytes of unrelated text.

In all cases the text goes only to the local inference backend the router
picks (Apple Foundation Models, the bundled Gemma 4 model, or your Ollama
daemon) — never off-device. Plugins that downstream the text further:

- **Sentiment Guard** re-windows to ~800 chars around the caret before
  hashing and sending for tone classification.
- **Burnout Copilot** re-windows to ~800 chars before its yes/no tone call.
- **Snippet Expander (AI snippets)** sends the 500 chars *immediately
  preceding* the trigger as prior context; the ⌃⌥R rephrase hotkey sends only
  the currently selected text.
- **Ask Halen** sends your typed question plus the context you can see in the
  palette — the focused app name, the current selection, and the most recent
  clipboard entry.
- **Meeting Prep** sends EventKit event titles, attendee names, and notes
  — never anything from focused text fields.
- **Typo Fixer** does string diffs locally; it never sends text to a model.
- **Voice Dictation** streams audio buffers to `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true` (see below).

## What stays local

Everything by default. Concretely:

- **Typo dictionary** — `~/Library/Application Support/Halen/typos.json`. Local file. Editable.
- **Sentiment rules** — `~/Library/Application Support/Halen/com.halen.sentiment-guard/rules.json`. Local file.
- **Approved-draft fingerprints** — `~/Library/Application Support/Halen/com.halen.sentiment-guard/approved.json`. **SHA-256 hex digests** of windowed drafts the user marked "Looks fine". The plaintext is *not* persisted — only the hash.
- **Snippets** — `~/Library/Application Support/Halen/com.halen.snippet-expander/snippets.json`. Local file.
- **Briefed-event ids** — `~/Library/Application Support/Halen/com.halen.meeting-prep/processed.json`. Local file. Contains only EventKit event identifiers, not titles or contents.

## Network traffic

Inference itself never touches the network for the Apple Foundation Models
and bundled-llama.cpp backends — both run entirely on-device. The only
inference backend that uses a socket at all is **Ollama**, and it talks to
the loopback interface:

**HTTP POST to `http://localhost:11434/api/chat`** — the Ollama HTTP API. The
client is defined in
[`OllamaInferenceClient.swift`](../../Sources/Halen/Inference/OllamaInferenceClient.swift):

```swift
init(baseURL: URL = URL(string: "http://localhost:11434")!) { ... }
```

The endpoint defaults to `localhost:11434` but **is user-configurable** via
`OllamaSettings` (Settings → Inference) — for example to reach Ollama running
in a VM or on another machine on your LAN. It is never changed by Halen or by
a remote process; only you can point it elsewhere. The request body contains:

- The constructed prompt (windowed text from above, plus instructions)
- The model name (`gemma4:e2b` / `gemma4:e4b` / `gemma4:26b`)
- Generation options (`temperature`, `num_predict`, `stop`)

With the default endpoint, that traffic does not leave the loopback interface
unless you have configured Ollama itself to bind to a non-localhost address.

Two more outbound paths exist, both user-initiated and neither carrying any of
your text:

- **Bundled-model download.** If you choose to download the bundled Gemma 4
  model from Settings → Inference (instead of using Apple Intelligence or a
  `BUNDLE_MODEL=1` build), `ModelDownloader` fetches a single GGUF file from
  Hugging Face (`huggingface.co/unsloth/gemma-4-E4B-it-GGUF`). This is a
  one-time file transfer, not telemetry.
- **Browser extension bridge.** If you enable the WebSocket bridge for the
  optional browser extension, Halen listens on `127.0.0.1:50765` (loopback
  only) so the extension can forward typing events from browser text fields.

There is **no analytics SDK, no remote logging endpoint, no auto-updater, and
no crash reporter** anywhere in the project. Nothing about your text, voice,
or calendar is ever uploaded.

## Apple on-device speech recognition

Voice Dictation uses `SFSpeechRecognizer` with:

```swift
req.requiresOnDeviceRecognition = true
```

Set in
[`VoiceDictationRecorder.swift`](../../Sources/Halen/Features/VoiceDictation/VoiceDictationRecorder.swift).

When `requiresOnDeviceRecognition = true`, Apple's recogniser refuses to
fall back to a server-side path: if the on-device model for your locale
isn't installed, the request fails outright (`recognizerUnavailable`)
rather than silently round-tripping audio to Apple. This is the line
that keeps Voice Dictation honest.

The model itself is downloaded by macOS the first time you enable
Dictation for a language (System Settings → Keyboard → Dictation). Once
installed, recognition runs entirely on the Neural Engine.

## EventKit

Burnout Copilot and Meeting Prep ask for **full Calendars access** via
`EKEventStore.requestFullAccessToEvents()`. Both plugins:

- Read events (titles, start/end, attendees, notes) from the system
  calendar database.
- Burnout Copilot also **writes** a single `🌿 Halen break` event when
  the user accepts the break suggestion. No other writes.

Calendar data flows through the same pipeline as everything else: read
into memory, sent to the local inference backend if needed (Meeting Prep),
never persisted outside macOS's own EventKit store.

## Telemetry

**There is none.** No analytics, no usage metrics, no error reporting,
no remote feature flags. Logging goes to stderr and the unified system
log via the small `Log` helper in
[`Sources/Halen/Support/Log.swift`](../../Sources/Halen/Support/Log.swift).
Nothing is uploaded.

## Permissions, summarised

| Permission | Used by | Why |
|---|---|---|
| Accessibility           | host (CaretObserver) | Read focused text, write back corrections / dictation / snippets |
| Microphone              | Voice Dictation      | Capture audio for SFSpeechRecognizer |
| Speech Recognition      | Voice Dictation      | Convert audio to text **on-device** |
| Calendars (full access) | Burnout Copilot, Meeting Prep | Read events; Burnout writes the `🌿 Halen break` event |
| Notifications           | Meeting Prep         | Post the "briefing ready" alert |
| Input Monitoring        | Ask Halen, Snippet Expander | Match the ⌃H and ⌃⌥R hotkeys system-wide — only those hotkeys, no other keystrokes |

You can deny any of these and the host continues to run. The dependent
plugins surface their own "permission required" detail-view state with a
one-click jump to System Settings.
