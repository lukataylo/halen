# Halen Wiki

Writing tools moved to the cloud while you weren't looking.

Halen is the move back. A menubar app that watches the text near your
cursor and runs small, focused plugins against it — fixing typos,
catching hostile drafts, expanding snippets, briefing you before a
meeting, nudging you to take a break.

Every plugin runs locally. Apple Silicon is fast enough for that now.

No cloud round-trips. No drafts uploaded. No accounts.

Your words stay yours. Not as a feature. As a default.

---

## How it's put together

- **One AX pipeline.** A single `CaretObserver` translates macOS
  Accessibility notifications into a typed event stream
  (`text.pause`, `caret.moved`, `app.focused`). Plugins subscribe;
  they never touch AX themselves.
- **Same contract, in-process or out.** Event names are JSON-RPC
  method names. In-process plugins call them via Swift. External
  plugins read NDJSON over stdio. Burnout Copilot and Meeting Prep
  already run out-of-process; the rest live inside the menubar app
  for now.
- **Tier-based, multi-backend inference.** Plugins ask for
  `classifier`, `small`, `medium`, or `large`. `RouterInferenceClient`
  picks a backend and falls through on failure. The `.classifier`
  tier routes to a dedicated Qwen 2.5 0.5B model so tone scans stay
  sub-second warm.
- **AX write-back, not synthetic keystrokes.** Corrections and snippet
  expansions use `kAXSelectedTextRangeAttribute` +
  `kAXSelectedTextAttribute`. Quieter, faster, more accurate.
- **A marketplace UI in the menubar.** Category-grouped plugin list,
  per-plugin toggle, per-plugin detail panel. Onboarding walks you
  through what to enable. Defaults are tuned for *useful without
  surprises*.

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

Ten plugins ship inside the menubar binary. The marketplace dropdown
toggles them on or off and opens their detail panel.

| Plugin | Category | Default | What it does |
|---|---|---|---|
| Ask Halen | Productivity | On | ⌃H opens a floating palette. Asks one question with your focused app, selection, and clipboard already in context. |
| [Typo Fixer](plugins/typo-fixer.md) | Writing | On | Replaces known typos at word boundaries. Learns new ones from how you edit. |
| [Sentiment Guard](plugins/sentiment-guard.md) | Writing | On | Classifies your drafts on-device. Pops a warning when the tone trips a rule you set. |
| [Snippet Expander](plugins/snippet-expander.md) | Productivity | On | `;tag` expands to static, dynamic, or AI-generated text. ⌃⌥R rephrases the selection in place. |
| [Clarity Checker](plugins/clarity-checker.md) | Writing | On | Flags passive voice, run-ons, vague phrasing. One-tap Gemma rewrite. |
| [Voice Dictation](plugins/voice-dictation.md) | Voice | Off | ⌃⌥Space opens a listening pill. Apple's on-device speech recognizer transcribes; the text lands at your caret. |
| [Inline Autocomplete](plugins/autocomplete.md) | Writing | Off | Suggests the next few words as ghost text. Tab to accept. |
| [Personal Style Guide](plugins/style-guide.md) | Writing | Off | Your banned-words → preferred-words list, scanned per paragraph. |
| [Email Reply](plugins/email-reply.md) | Productivity | Off | ⌃⌥E drafts a reply to the email you're reading, in the tone you pick. |
| [Tone Profiles](plugins/tone-profiles.md) | Writing | Off | Per-app tone hints (formal vs casual), shared with the other writing plugins. |

## External plugins (out-of-process, JSON-RPC over stdio)

Same `HalenPlugin` contract, just over a stdio socket instead of a
Swift call. Ship in this repo under [`plugins/`](../../plugins/) and
install into `~/Library/Application Support/Halen/Plugins/`.

| Plugin | Category | What it does |
|---|---|---|
| [Burnout Copilot](plugins/burnout-copilot.md) | Focus | Three signals. Two of three trip. "Take 10?" with a calendar block + Shortcuts integration. |
| [Meeting Prep](plugins/meeting-prep.md) | Scheduling | 15 minutes before each event, drops a 5-bullet Gemma briefing on your clipboard. |

## Source pointers

- Plugin protocol: [`Sources/Halen/Plugins/HalenPlugin.swift`](../../Sources/Halen/Plugins/HalenPlugin.swift)
- Registry: [`Sources/Halen/Plugins/PluginRegistry.swift`](../../Sources/Halen/Plugins/PluginRegistry.swift)
- AX pipeline: [`Sources/Halen/Accessibility/CaretObserver.swift`](../../Sources/Halen/Accessibility/CaretObserver.swift)
- Inference: [`Sources/Halen/Inference/RouterInferenceClient.swift`](../../Sources/Halen/Inference/RouterInferenceClient.swift)
- Build script: [`scripts/build-app.sh`](../../scripts/build-app.sh)
