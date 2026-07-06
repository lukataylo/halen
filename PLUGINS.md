# Writing Halen plugins

A Halen plugin is **a folder and a JSON manifest**. No store, no submission
process, no SDK. Drop the folder into
`~/Library/Application Support/Halen/Plugins/`, toggle it on in the menubar,
done.

There are two kinds:

- **External plugins** — any executable (Python, Node, a shell script, a
  compiled binary) speaking newline-delimited JSON-RPC 2.0 over stdio. This
  is the format for everyone who isn't compiled into Halen. This document is
  mostly about these.
- **First-party plugins** — Swift modules compiled into the app. Each lives
  in `Sources/Plugins/<Name>/` and may depend on exactly one target:
  `HalenPluginAPI`. The dependency list in `Package.swift` is the proof —
  a first-party plugin physically cannot import host internals, so the same
  API you get is the API the bundled plugins survive on.

Both kinds declare the same manifest and pass through the same permission
layer. The permissions screen in the menubar shows every plugin with every
capability it declared, each individually revocable.

## The manifest

`<your-plugin-folder>/halen-plugin.json`:

```json
{
  "id": "com.example.clipboard-cleaner",
  "name": "Clipboard Cleaner",
  "summary": "Press ⌃⌥⇧V to strip tracking junk from your clipboard.",
  "version": "1.0.0",
  "halenApiVersion": "0.1",
  "executable": "/usr/bin/python3",
  "args": ["plugin.py"],
  "events": ["hotkey.fired"],
  "capabilities": ["clipboard", "hotkeys", "notifications"],
  "icon": "doc.on.clipboard",
  "category": "productivity"
}
```

| Field | Meaning |
|---|---|
| `id` | Reverse-DNS, permanent. Keys settings, grants, and the on-disk folder. No `/`, no `..`, ≤128 chars. |
| `halenApiVersion` | Protocol version. Currently `"0.1"`. The host refuses manifests it doesn't recognise. |
| `executable` | Absolute path, or relative to the plugin folder (relative paths must stay inside it — traversal is rejected). |
| `events` | Topics pushed to your stdin. Anything not listed is filtered before it reaches you. |
| `capabilities` | Everything you intend to observe or do. Undeclared = unavailable; declared = revocable by the user. |
| `icon` | SF Symbol name for the plugin row. |
| `category` | `writing` / `voice` / `scheduling` / `focus` / `productivity` / `agents`. |

## Capabilities

Declare only what you use. Calls gated by an undeclared or revoked
capability fail with JSON-RPC error `-32001`.

| Capability | Grants |
|---|---|
| `observe-text` | `text.pause` + `caret.moved` events, `ax/readSelection` |
| `observe-apps` | `app.focused` events |
| `observe-keystrokes` | (declaration of intent for keystroke reconstruction; first-party only today) |
| `observe-screen` | screen capture (also needs macOS Screen Recording) |
| `process-observation` | watching local agent processes, transcripts, IPC sockets (Notch Boss) |
| `insert-text` | `ax/replaceRange` |
| `popover-ui` | `ui/prompt` |
| `notifications` | `ui/toast` |
| `speak` | speech synthesis (first-party API only today) |
| `run-shortcuts` | running Shortcuts.app shortcuts (first-party API only today) |
| `hotkeys` | `hotkey/register`, `hotkey/unregister` |
| `clipboard` | `clipboard/read`, `clipboard/write` |
| `microphone`, `speech-recognition` | mic + on-device speech (also need the macOS permissions) |
| `calendar` | `calendar/upcomingEvents`, `calendar/createEvent` |
| `automation` | AppleScript against other apps (also needs macOS Automation) |
| `notch-overlay` | the notch surface — one plugin at a time (first-party API only today) |
| `tone-profiles` | `profile/getToneProfile`, `profile/setToneProfile`, `profile/listToneProfiles` |
| `snippets` | the shared snippet library (first-party API only today) |

## The wire protocol

Newline-delimited JSON-RPC 2.0. One JSON object per line. Host → your
stdin; you → stdout; stderr is your free-form log (forwarded to Halen's
log).

Lifecycle:

1. Host sends `initialize` (request). Reply with any result, e.g. `{}`.
2. Host sends `notifications/initialized` (notification). You're live.
3. Events arrive as notifications: `{"method": "event/<topic>", "params": {"topic": ..., "payload": {...}}}`.
4. You call host methods as ordinary requests with an `id`; responses come
   back on stdin.
5. On disable/quit: host sends a `shutdown` request (reply!), then an
   `exit` notification, then SIGTERM, then SIGKILL. Be polite; exit at
   `exit`.

### Events

| Topic | Payload |
|---|---|
| `text.pause` | `appBundleId`, `appName`, `text` (±4k chars around the caret), `caretOffset`, `timestamp` |
| `caret.moved` | `appBundleId`, `rect {x,y,width,height}`, `timestamp` |
| `app.focused` | `appBundleId`, `appName`, `timestamp` |
| `finding.detected` / `finding.cleared` | another plugin flagged/cleared a paragraph (read-only) |
| `hotkey.fired` | `id` (your registration id), `timestamp` |

### Host methods

| Method | Params → Result | Capability |
|---|---|---|
| `inference/complete` | `prompt`, `tier` (`classifier`/`small`/`medium`/`large`), `maxTokens`, `temperature`, `stop`, `taskKind` → `{text, modelId, latencyMs}` | — |
| `ax/readSelection` | → `{text, appBundleId, location, length}` | `observe-text` |
| `ax/replaceRange` | `text`, `location`, `length` → `{ok}` | `insert-text` |
| `ui/toast` | `title`, `body` → `{ok}` | `notifications` |
| `ui/prompt` | `title`, `body`, `actions[]`, `timeoutSeconds?` → `{action}` (null on dismiss) | `popover-ui` |
| `clipboard/read` | → `{text}` | `clipboard` |
| `clipboard/write` | `text` → `{ok}` | `clipboard` |
| `hotkey/register` | `id`, `keyCode` (Carbon kVK), `modifiers` (Carbon mask) → `{ok}`; fires `hotkey.fired` | `hotkeys` |
| `hotkey/unregister` | `id` → `{ok}` | `hotkeys` |
| `calendar/upcomingEvents` | `withinHours`, `max` → `{events[]}` | `calendar` |
| `calendar/createEvent` | `title`, `start` (epoch), `durationMinutes` → `{id}` | `calendar` |
| `profile/getToneProfile` / `setToneProfile` / `listToneProfiles` | per-app formal/casual register | `tone-profiles` |

Errors use standard JSON-RPC codes plus: `-32001` permission denied,
`-32002` inference unavailable, `-32003` AX write failed.

`inference/complete` is deliberately ungated: shared access to the local
model is the platform's baseline, and a prompt can't touch anything the
other capabilities guard. It never leaves the machine.

## The example: Clipboard Cleaner

The whole plugin is [`examples/clipboard-cleaner/`](examples/clipboard-cleaner/)
— a manifest and ~100 lines of dependency-free Python. Install it:

```bash
mkdir -p ~/Library/Application\ Support/Halen/Plugins/com.example.clipboard-cleaner
cp examples/clipboard-cleaner/* ~/Library/Application\ Support/Halen/Plugins/com.example.clipboard-cleaner/
```

Toggle it on in the menubar, copy an URL full of `utm_*` junk, press
⌃⌥⇧V, paste. Open the permissions screen and revoke its `clipboard`
capability to watch enforcement work.

`scripts/plugin-smoke-test.py` drives the real initialize handshake against
every plugin folder you point it at — useful before shipping yours.

## First-party (Swift) plugins

Read `Sources/HalenPluginAPI/PluginContext.swift` — that file *is* the API.
A plugin gets a `PluginContext` whose services are nil for anything it
didn't declare: `events`, `inference`, `storage`, `permissions` always;
`text`, `ui`, `hotkeys`, `clipboard`, `speech`, `shortcuts`, `screen`,
`notch`, `toneProfiles`, `snippets` by capability. The six bundled plugins
under `Sources/Plugins/` are the reference implementations — Writing
Assistant for the classify-and-suggest loop, Snippet Expander for text
actuation, Notch Boss for something far heavier than text tools.

## Deliberately not here (yet)

- **No sandbox.** An external plugin is a process running as you. The
  manifest is enforced at the RPC boundary, not by an OS sandbox. Install
  plugins you've read.
- **No store, no signing, no update channel for plugins.** The directory is
  a folder. If strangers ever write plugins, these get built then.
- **No streaming over RPC** (`inference/complete` blocks; first-party
  plugins get streaming through the Swift API).
- **No runtime capability requests.** Everything is declared up front or
  not at all — that's a feature.
