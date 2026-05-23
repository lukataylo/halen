<p align="center">
  <img src="assets/readme-header.png" alt="Halen — Local AI at your cursor. Floating product mockups of email composer, project brief editor, notes app, snippets and tone suggestions, all on a cobalt background." />
</p>

<p align="center">
  <strong>Local-first AI companion for macOS.</strong><br>
  No cloud. No upload. Just you, your data, your rules.<br>
  <a href="https://halen.dev">halen.dev</a>
</p>

---

Halen is a menubar app that watches the text near your cursor and runs a set of small, focused **plugins** against it. Every plugin runs locally — typo correction is a static dictionary; everything else goes through a local [Gemma 4](https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/) model. Inference routes across whatever's available on your Mac — Apple Intelligence, a bundled Gemma 4 model on llama.cpp, or your own [Ollama](https://ollama.com) daemon. The text never leaves your Mac.

## What's in the box

Seven plugins ship with Halen out of the box. Each one is a small Swift module conforming to `HalenPlugin`; the marketplace dropdown lets you toggle them on/off and dive into per-plugin settings.

| Plugin | Category | What it does |
|---|---|---|
| **Ask Halen** | Productivity | Press ⌃H anywhere. A floating palette opens with your focused app, selected text, and recent clipboard already in context — ask a one-shot question and the answer is inserted at your cursor. |
| **Typo Fixer** | Writing | Replaces your known typos inline as you type. Seeded with a personal dictionary of 32 frequent slips; learns new ones automatically from your edits. Backspace + retype to "undo" a bad correction — it demotes the entry forever. |
| **Sentiment Guard** | Writing | When you finish a sentence in any text field, Gemma 4 classifies the tone against a set of rules you control (5 built-in + add your own). Hostile or irritated? Halen shows a popover asking whether to send anyway or have Gemma rephrase to your clipboard. |
| **Voice Dictation** | Voice | Press ⌥⌘H anywhere. A live waveform pill follows your cursor while you speak. Apple's on-device speech recognition transcribes locally; the text lands at the caret on stop. |
| **Snippet Expander** | Productivity | Type `;sig` or `;today` or `;summary` followed by a space — Halen swaps it for static text, computed values, or a Gemma-generated rewrite of whatever you wrote above. Add your own with custom Gemma prompts. Also: select text anywhere and press ⌃⌥R to rewrite just that selection in place. |
| **Burnout Copilot** | Focus | Watches three signals — time in distraction apps, recent tone trend, calendar density — and pops a *"Take 10?"* suggestion when 2 of 3 trip. One click creates a calendar break and triggers your Focus Shortcut. |
| **Meeting Prep** | Scheduling | 15 minutes before your next event, Gemma 4 reads the calendar entry and drops a 5-bullet briefing on your clipboard. A notification fires; the briefing also lives in the plugin's recent-briefings list. |

## How it works

```
┌──────────────────────────────────────────────────────────────────┐
│                       HALEN MENUBAR APP                          │
│                                                                  │
│  CaretObserver ──┐                                               │
│  (AX events)     │                                               │
│                  ▼                                               │
│              EventBus ──► text.pause, caret.moved, ...           │
│                  │                                               │
│        ┌─────┬───┴──┬──────┬──────┬──────┬──────┐                │
│        ▼     ▼      ▼      ▼      ▼      ▼      ▼                │
│      Ask   Typo  Sentiment Snippet Voice  Burnout Meeting        │
│      Halen  Fixer  Guard   Expand. Dict.  Copilot Prep           │
│        │     │      │      │      │       │      │               │
│        └──┬──┴──────┴──────┴──────┴───────┴──────┘               │
│           ▼                                                      │
│   RouterInferenceClient ──┬──► Apple Foundation Models           │
│   (picks per request,     ├──► bundled Gemma 4 on llama.cpp      │
│    falls through on fail) └──► Ollama on localhost:11434         │
└──────────────────────────────────────────────────────────────────┘
```

- **Host (this app)** owns macOS Accessibility caret tracking, the event bus, the multi-backend inference router, persistent storage, and the SwiftUI menubar UI.
- **Plugins** subscribe to events on the bus, optionally call inference, and write back to the focused text field via AX. They're in-host Swift modules today; the contract is already shaped to lift them out-of-process to JSON-RPC later (`text.pause` event names line up with future method names) — an out-of-process plugin host and a loopback WebSocket bridge (for the browser extension) are already wired in.
- **Inference** goes through `RouterInferenceClient`, which routes each request to the best available backend and falls through to the next on failure. Three backends ship: **Apple Foundation Models** (macOS 26+, zero install), a **bundled Gemma 4 E4B model on llama.cpp** (downloaded on first use, or bundled into the `.app` with `BUNDLE_MODEL=1`), and your local **Ollama** daemon (opt-in, the only backend serving the large tier). Plugins request a *tier* (`small` / `medium` / `large`) and a task kind — the host picks the backend and model. The backend order is user-configurable in Settings.

Full architecture and per-plugin internals: see [`docs/wiki/`](docs/wiki/).

## Quickstart

**Prerequisites**
- macOS 14 Sonoma or later
- Xcode command-line tools (`xcode-select --install`)
- An inference backend. Halen picks whatever's available, so any one of:
  - **Apple Intelligence** (macOS 26+) — nothing to install.
  - The **bundled Gemma 4 E4B model** — fetched on first use by the in-app downloader (Settings → Inference), or baked into the `.app` with a `BUNDLE_MODEL=1` build.
  - **[Ollama](https://ollama.com)** with `gemma4:e4b` (and optionally `gemma4:e2b` / `gemma4:26b`):
    ```bash
    ollama pull gemma4:e4b
    ollama pull gemma4:e2b   # smaller / faster — used by classification paths
    ```

**Build and launch**
```bash
git clone https://github.com/lukataylo/halen.git
cd halen
./scripts/run-dev.sh
```

`run-dev.sh` calls `build-app.sh` (which builds the SPM target, assembles `build/Halen.app`, embeds `llama.framework`, and signs with your Apple Development cert so TCC permissions persist across rebuilds), quits any prior instance, launches the app, and streams its log. For a notarization-ready release build, follow [`docs/RELEASING.md`](docs/RELEASING.md) — the three-script chain that produces a signed, notarized, drag-to-Install DMG.

**Grant permissions**
1. **Accessibility** — Halen prompts on first launch. Add `build/Halen.app` to System Settings → Privacy & Security → Accessibility. *Without this, no plugin can see or modify text.*
2. **Microphone + Speech Recognition** — requested the first time you use Voice Dictation.
3. **Calendar + Notifications** — requested by Burnout Copilot and Meeting Prep when you open them.
4. **Input Monitoring** — used by Ask Halen (⌃H) and Snippet Expander's rephrase hotkey (⌃⌥R) so those shortcuts fire from other apps. Without it the hotkeys still work while Halen itself is frontmost; grant it under System Settings → Privacy & Security → Input Monitoring for system-wide use.

## Privacy

Everything that processes your text — typo matching, tone classification, snippet expansion, dictation — runs **locally on your machine**. Inference stays on-device whether it goes to Apple Foundation Models, the bundled Gemma 4 model, or your local Ollama daemon (HTTP to `localhost:11434`). The only other network traffic Halen can generate is a one-time download of the bundled model from Hugging Face, if you opt into it from Settings. No telemetry, no analytics, no error reporting calls. The `docs/wiki/privacy.md` page goes through this in detail.

## Demo

A scripted **1-minute demo** is in [`docs/DEMO.md`](docs/DEMO.md). Beat-by-beat: typo correction → sentiment popover → text expansion → meeting prep.

## Repository layout

```
Sources/Halen/
├── App/                 # SwiftUI App, AppCoordinator, marketplace UI, settings
├── Plugins/             # HalenPlugin protocol, PluginRegistry, HalenServices,
│                        #   out-of-process plugin host + WebSocket bridge
├── Features/            # the seven bundled plugins, one folder/file each
├── Accessibility/       # AX permission flow, caret/focused-element observer
├── Inference/           # RouterInferenceClient, backends (Apple FM / llama.cpp /
│                        #   Ollama), tiers, model downloader
├── Events/              # in-process EventBus + Codable event payloads
├── Overlay/             # caret-following indicator window
└── Support/             # Log, string diff, Levenshtein, windowing helpers

Tests/HalenTests/        # ~110 unit tests (router, event bus, manifests, …)
Resources/               # AppIcon.icns, menubar template, source SVG
Vendor/                  # pinned llama.cpp xcframework + version
docs/                    # README hero, site assets, landing page, wiki
scripts/                 # build-app.sh, run-dev.sh, fetch-assets.sh,
                         #   notarize.sh, generate-icons.swift
```

## Build, test, CI

`swift build` / `swift test` from the repo root. The full suite is ~110 tests
under `Tests/HalenTests/`. [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
runs `swift build` + `swift test` + a release-config build on every push and PR
to `main` (macOS 14 runner).

## License

MIT — see [`LICENSE`](LICENSE). Gemma 4 itself is governed by Google's
[Gemma terms](https://ai.google.dev/gemma/terms); the model weights are not
redistributed in this repository (the bundled model is downloaded on demand).
