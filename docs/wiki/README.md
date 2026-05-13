# Halen Wiki

Halen is a **local-first, cursor-following writing agent for macOS** that lives
in your menu bar. It watches the focused text field via Accessibility (AX),
listens for `text.pause` / `caret.moved` / `app.focused` events, and runs a
small fleet of plugins that act on what you're typing — fixing typos, flagging
hostile drafts, expanding snippets, dictating speech, briefing you before
meetings, and nudging you to take a break when you've been at it too long.

All inference is local. The default backend is **Ollama** running
`gemma4:e2b` (small / fast) and `gemma4:e4b` (medium / default). Speech
recognition is Apple's on-device `SFSpeechRecognizer`. Nothing about your
text, voice, or calendar leaves the machine.

## What's clever about it

- **One AX pipeline, many plugins.** A single `CaretObserver` translates AX
  notifications into a typed event stream. Plugins subscribe to that stream
  through a tiny `HalenPlugin` protocol — they never touch AX themselves.
- **Event names are JSON-RPC method names in disguise.** `text.pause`,
  `caret.moved`, `app.focused` are already wire-compatible with the future
  out-of-process plugin runtime (M4). Today plugins live in-process; tomorrow
  the same contract works over a socket.
- **Tier-based inference.** Plugins ask for `small`, `medium`, or `large`.
  The host maps those to a concrete model. Swap Ollama for MLX later without
  touching any plugin code.
- **AX write-back, not synthetic keystrokes.** Corrections, snippet expansions,
  and dictation inserts use `kAXSelectedTextRangeAttribute` +
  `kAXSelectedTextAttribute`. Quieter, faster, more accurate than synthesizing
  keypresses.
- **Marketplace UI.** The menubar popover is a category-grouped list of
  plugins with per-plugin toggle + detail panel — the same shape you'd expect
  from a real plugin store.

## Table of contents

- [Architecture](architecture.md) — host vs plugins, event bus, AX pipeline, inference layer, storage.
- [Getting started](getting-started.md) — prerequisites, build, TCC permissions, mic/speech/calendar prompts.
- [Privacy](privacy.md) — what Halen sees, what stays local, network traffic, telemetry.

### Plugins

| Plugin | Category | What it does |
|---|---|---|
| [Typo Fixer](plugins/typo-fixer.md) | Writing | Auto-replaces known typos at word boundaries; learns new corrections by watching how you edit. |
| [Sentiment Guard](plugins/sentiment-guard.md) | Writing | Classifies your drafts with Gemma 4 E4B and surfaces a popover when the tone trips a rule. |
| [Voice Dictation](plugins/voice-dictation.md) | Voice | ⌥⌘Space → on-device speech recognition → inserts at the caret. |
| [Snippet Expander](plugins/snippet-expander.md) | Productivity | `;tag` expands to static, dynamic, or AI-generated text. |
| [Burnout Copilot](plugins/burnout-copilot.md) | Focus | Three signals → 2-of-3 trip → "Take 10?" popup with calendar + Shortcuts integration. |
| [Meeting Prep](plugins/meeting-prep.md) | Scheduling | 15 minutes before each event, drops a 5-bullet Gemma briefing on your clipboard. |

## Quick links

- Top-level repo: [`/Users/lukadadiani/Documents/halen`](../../)
- Plugin protocol: [`Sources/Halen/Plugins/HalenPlugin.swift`](../../Sources/Halen/Plugins/HalenPlugin.swift)
- Registry: [`Sources/Halen/Plugins/PluginRegistry.swift`](../../Sources/Halen/Plugins/PluginRegistry.swift)
- AX pipeline: [`Sources/Halen/Accessibility/CaretObserver.swift`](../../Sources/Halen/Accessibility/CaretObserver.swift)
- Inference: [`Sources/Halen/Inference/OllamaInferenceClient.swift`](../../Sources/Halen/Inference/OllamaInferenceClient.swift)
- Build script: [`scripts/build-app.sh`](../../scripts/build-app.sh)
