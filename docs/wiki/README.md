# Halen Wiki

Halen is a menubar writing assistant for macOS. Models run on-device.
Your text never leaves your Mac.

---

## How it's put together

- **One AX pipeline.** A single `CaretObserver` translates macOS
  Accessibility notifications into a typed event stream
  (`text.pause`, `caret.moved`, `app.focused`). Plugins subscribe;
  they never touch AX themselves.
- **Same contract, in-process or out.** Event names are JSON-RPC
  method names. In-process plugins call them via Swift. External
  plugins read NDJSON over stdio. Burnout Copilot and Meeting Prep
  run out-of-process; bundled plugins live inside the menubar app.
- **Tier-based, multi-backend inference.** Plugins ask for
  `classifier`, `small`, `medium`, or `large`. `RouterInferenceClient`
  picks a backend and falls through on failure. The `.classifier`
  tier routes to a dedicated Qwen 2.5 0.5B model so tone scans stay
  sub-second warm.
- **AX write-back, not synthetic keystrokes.** Corrections and snippet
  expansions use `kAXSelectedTextRangeAttribute` +
  `kAXSelectedTextAttribute`. Quieter, faster, more accurate.
- **A marketplace UI in the menubar.** A flat plugin list, per-plugin
  toggle, per-plugin detail panel. Onboarding walks you through what to
  enable. Defaults are tuned for *useful without surprises*.

## Read the deep dives

- [Architecture](architecture.md) — host vs plugins, event bus, AX
  pipeline, inference layer, storage.
- [Getting started](getting-started.md) — prerequisites, build, TCC
  permissions, mic / speech / calendar prompts.
- [Privacy](privacy.md) — what Halen sees, what stays local, every
  byte of network traffic, telemetry stance.
- [Accessibility](accessibility.md) — the bar Halen holds itself to,
  the smoke test we run before every release.

## Bundled plugins (in-process)

Six plugins ship inside the menubar binary. The marketplace dropdown
toggles them on or off and opens their detail panel.

| Plugin | Category | Default | What it does |
|---|---|---|---|
| Ask Halen | Productivity | On | ⌃H opens a floating palette. One question, with your focused app + selection + clipboard as context. |
| [Word Replacements](plugins/word-replacements.md) | Writing | On | Fixes your typos. Swaps in your preferred terms. |
| [Writing Coach](plugins/writing-coach.md) | Writing | On | Catches hostile tone and clarity issues. One tap to rewrite. |
| [Snippet Expander](plugins/snippet-expander.md) | Productivity | On | `;tag` expands. `;reply` or ⌃⌥E drafts an email. ⌃⌥R rewrites a selection. |
| [Voice Dictation](plugins/voice-dictation.md) | Voice | Off | ⌃⌥Space opens a listening pill. Apple's on-device transcription writes at your caret. |
| [Autocomplete](plugins/autocomplete.md) | Writing | Off | Suggests the next few words as ghost text. Tab to accept. |

## External plugins (out-of-process, JSON-RPC over stdio)

Same `HalenPlugin` contract, over a stdio socket instead of a Swift
call. Ship in this repo under [`plugins/`](../../plugins/) and install
into `~/Library/Application Support/Halen/Plugins/`.

| Plugin | Category | What it does |
|---|---|---|
| [Burnout Copilot](plugins/burnout-copilot.md) | Focus | Three signals. Two of three trip. "Take 10?" with a calendar block + Shortcuts integration. |
| [Meeting Prep](plugins/meeting-prep.md) | Scheduling | 15 minutes before each event, drops a 5-bullet Gemma briefing on your clipboard. |
| [Mother](plugins/mother.md) | Focus | Hardcore local discipline. Quits blocklisted apps and closes blocklisted browser tabs during your focus hours. No network. |

## Source pointers

- Plugin protocol: [`Sources/Halen/Plugins/HalenPlugin.swift`](../../Sources/Halen/Plugins/HalenPlugin.swift)
- Registry: [`Sources/Halen/Plugins/PluginRegistry.swift`](../../Sources/Halen/Plugins/PluginRegistry.swift)
- AX pipeline: [`Sources/Halen/Accessibility/CaretObserver.swift`](../../Sources/Halen/Accessibility/CaretObserver.swift)
- Inference: [`Sources/Halen/Inference/RouterInferenceClient.swift`](../../Sources/Halen/Inference/RouterInferenceClient.swift)
- Build script: [`scripts/build-app.sh`](../../scripts/build-app.sh)
