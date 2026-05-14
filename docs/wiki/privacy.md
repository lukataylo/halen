# Privacy

Halen is built around one constraint: **nothing leaves the machine.** This
page documents what data the app sees, where it's processed, and the few
egress points that do exist (all to localhost).

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

Plugins that downstream the text further:

- **Sentiment Guard** re-windows to ~800 chars around the caret before
  hashing and sending to Gemma.
- **Burnout Copilot** re-windows to ~800 chars before its yes/no tone call.
- **Snippet Expander (AI snippets)** sends the 500 chars *immediately
  preceding* the trigger as prior context.
- **Meeting Prep** sends EventKit event titles, attendee names, and notes
  — never anything from focused text fields.
- **Typo Fixer** does string diffs locally; it never sends text to Gemma.
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

Halen makes exactly one kind of outbound connection: **HTTP POST to
`http://localhost:11434/api/chat`**, the Ollama HTTP API on the loopback
interface. The client is defined in
[`OllamaInferenceClient.swift`](../../Sources/Halen/Inference/OllamaInferenceClient.swift):

```swift
init(baseURL: URL = URL(string: "http://localhost:11434")!) { ... }
```

The base URL is set in code; there is no setting that would let the user
or a process change it to a remote host. The request body contains:

- The constructed prompt (windowed text from above, plus instructions)
- The model name (`gemma4:e2b` / `gemma4:e4b` / `gemma4:26b`)
- Generation options (`temperature`, `num_predict`, `stop`)

That traffic does not leave the loopback interface unless the user has
configured Ollama itself to bind to a non-localhost address. By default
Ollama listens on `127.0.0.1` only.

There is **no other outbound network code** in the project — no analytics
SDK, no remote logging endpoint, no auto-updater, no crash reporter.
`URLSession` is only constructed once, inside the Ollama client.

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
into memory, sent to localhost Gemma if needed (Meeting Prep), never
persisted outside macOS's own EventKit store.

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

You can deny any of these and the host continues to run. The dependent
plugins surface their own "permission required" detail-view state with a
one-click jump to System Settings.
