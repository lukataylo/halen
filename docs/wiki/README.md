# Halen Wiki

Halen is a **local-first, cursor-following writing agent for macOS** that lives
in your menu bar. It watches the focused text field via Accessibility (AX),
listens for `text.pause` / `caret.moved` / `app.focused` events, and runs a
small fleet of plugins that act on what you're typing — fixing typos, flagging
hostile drafts, expanding snippets, dictating speech, briefing you before
meetings, and nudging you to take a break when you've been at it too long.

All inference is local. `RouterInferenceClient` routes each request across
whatever backends are available — **Apple Foundation Models** (macOS 26+), a
**bundled Gemma 4 E4B model on llama.cpp**, and a local **Ollama** daemon —
falling through to the next on failure. Speech recognition is Apple's
on-device `SFSpeechRecognizer`. Nothing about your text, voice, or calendar
leaves the machine.

## What's clever about it

- **One AX pipeline, many plugins.** A single `CaretObserver` translates AX
  notifications into a typed event stream. Plugins subscribe to that stream
  through a tiny `HalenPlugin` protocol — they never touch AX themselves.
- **Same contract, in-process or out.** Event names (`text.pause`,
  `caret.moved`, `app.focused`) are JSON-RPC method names. In-process plugins
  call them via Swift; external plugins read NDJSON over stdio. Burnout
  Copilot and Meeting Prep already run out-of-process; the rest live inside
  the menubar app for now.
- **Tier-based, multi-backend inference.** Plugins ask for `classifier`,
  `small`, `medium`, or `large` (and a task kind). `RouterInferenceClient`
  picks a concrete backend + model and falls through on failure. Adding or
  reordering backends never touches plugin code. The `.classifier` tier
  routes to a dedicated Qwen 2.5 0.5B backend so tone scans stay sub-second
  warm.
- **AX write-back, not synthetic keystrokes.** Corrections, snippet expansions,
  and dictation inserts use `kAXSelectedTextRangeAttribute` +
  `kAXSelectedTextAttribute`. Quieter, faster, more accurate than synthesizing
  keypresses.
- **Marketplace UI.** The menubar popover is a category-grouped list of
  plugins with per-plugin toggle + detail panel — the same shape you'd expect
  from a real plugin store. First-run onboarding walks the user through what
  to enable; defaults are tuned for "useful without surprises."

## Table of contents

- [Architecture](architecture.md) — host vs plugins, event bus, AX pipeline, inference layer, storage.
- [Getting started](getting-started.md) — prerequisites, build, TCC permissions, mic/speech/calendar prompts.
- [Privacy](privacy.md) — what Halen sees, what stays local, network traffic, telemetry.

### Bundled plugins (in-process)

These ten plugins live inside the menubar binary; the marketplace dropdown
toggles them on/off and opens their per-plugin detail panel.

| Plugin | Category | Default | What it does |
|---|---|---|---|
| Ask Halen | Productivity | On | ⌃H → a floating palette that answers a one-shot question with your focused app, selection, and clipboard in context. |
| [Typo Fixer](plugins/typo-fixer.md) | Writing | On | Auto-replaces known typos at word boundaries; learns new corrections by watching how you edit. |
| [Sentiment Guard](plugins/sentiment-guard.md) | Writing | On | Classifies your drafts with a local classifier and surfaces a popover when the tone trips a rule. |
| [Snippet Expander](plugins/snippet-expander.md) | Productivity | On | `;tag` expands to static, dynamic, or AI-generated text; ⌃⌥R rephrases a selection in place. |
| [Clarity Checker](plugins/clarity-checker.md) | Writing | On | Flags passive voice, run-ons, and vague phrasing; one-tap Gemma rewrite. |
| [Voice Dictation](plugins/voice-dictation.md) | Voice | Off | ⌥⌘H → on-device speech recognition → inserts at the caret. |
| [Inline Autocomplete](plugins/autocomplete.md) | Writing | Off | Suggests the next few words as ghost text; Tab to accept. |
| [Personal Style Guide](plugins/style-guide.md) | Writing | Off | Your banned-words → preferred-words list, scanned per paragraph. |
| [Email Reply](plugins/email-reply.md) | Productivity | Off | ⌃⌥E drafts a reply to the email you're reading, in the tone you pick. |
| [Tone Profiles](plugins/tone-profiles.md) | Writing | Off | Per-app tone hints (formal vs casual) shared with the other writing plugins. |

### External plugins (out-of-process, JSON-RPC over stdio)

Ship in this repo under [`plugins/`](../../plugins/) and install into
`~/Library/Application Support/Halen/Plugins/`. Same `HalenPlugin` contract,
just over a stdio socket instead of a Swift call.

| Plugin | Category | What it does |
|---|---|---|
| [Burnout Copilot](plugins/burnout-copilot.md) | Focus | Three signals → 2-of-3 trip → "Take 10?" popup with calendar + Shortcuts integration. |
| [Meeting Prep](plugins/meeting-prep.md) | Scheduling | 15 minutes before each event, drops a 5-bullet Gemma briefing on your clipboard. |

## Quick links

- Top-level repo: [`/Users/lukadadiani/Documents/halen`](../../)
- Plugin protocol: [`Sources/Halen/Plugins/HalenPlugin.swift`](../../Sources/Halen/Plugins/HalenPlugin.swift)
- Registry: [`Sources/Halen/Plugins/PluginRegistry.swift`](../../Sources/Halen/Plugins/PluginRegistry.swift)
- AX pipeline: [`Sources/Halen/Accessibility/CaretObserver.swift`](../../Sources/Halen/Accessibility/CaretObserver.swift)
- Inference: [`Sources/Halen/Inference/RouterInferenceClient.swift`](../../Sources/Halen/Inference/RouterInferenceClient.swift)
- Build script: [`scripts/build-app.sh`](../../scripts/build-app.sh)
