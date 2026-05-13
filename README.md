# Halen

Local-first, cursor-following writing agent for macOS. Auto-fixes typos near your
caret in any text field; later milestones add tone/stress logging and a plugin
architecture so other features (calendar nudges, screen-time, …) can subscribe to
the same event stream.

Inference is local. Default model: **Gemma 4 E4B** (instruction-tuned), with E2B
as the small-tier fallback for fast typo paths. MLX runtime; wired up in M2.

## Status

Milestone | Scope | State
---|---|---
M1 | Menubar shell, Accessibility permission, caret observer, overlay window, event bus, inference protocol | In progress
M2 | MLX + Gemma 4 inference host, `typo-fixer` feature | Not started
M3 | `tone-logger` feature, local SQLite timeseries | Not started
M4 | Extract JSON-RPC plugin API; port features to it; ship a first out-of-process plugin | Not started

## Requirements

- macOS 14+ (Sonoma)
- Xcode command-line tools (`xcode-select --install`)
- Swift 5.10+ (ships with Xcode 15.3+; Swift 6 also fine)

## Build & run

```bash
./scripts/run-dev.sh
```

This builds the binary, assembles `build/Halen.app` (ad-hoc signed so the TCC
identity is stable), and launches the binary inside the bundle so stdout/stderr
stream to your terminal.

The first launch will trigger a system prompt asking you to grant Accessibility
permission. Click through, then:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click **+**, navigate to `build/Halen.app`, add it
3. Toggle it on

The app polls every 2 seconds; the menubar status will flip from "not granted"
to "granted" once you toggle it. The terminal will log `Accessibility granted —
would start observers here (task 3)`.

To rebuild without launching:

```bash
./scripts/build-app.sh
```

## Layout

```
Package.swift
Resources/Info.plist
scripts/
  build-app.sh       # SPM build + .app bundle assembly
  run-dev.sh         # build + launch with logs in terminal
Sources/Halen/
  App/               # SwiftUI App, AppDelegate, AppCoordinator, MenuBarExtra UI
  Accessibility/     # AX permission helpers (caret observer lands in M1 task 3)
  Events/            # in-process pub/sub + event payload types (JSON-serializable)
  Inference/         # InferenceClient protocol, ModelTier, stub impl
  Overlay/           # caret-following NSWindow (M1 task 4)
  Support/           # logging
```

## Architecture notes

- **Host vs plugins**: the menubar app owns AX capture, inference, persistence,
  overlay rendering. Features (typo-fixer, tone-logger) currently live in-host
  as Swift modules. In M4 they're extracted into out-of-process plugins talking
  JSON-RPC over a Unix socket. Event names (`text.pause`, `caret.moved`, …) are
  already chosen to be the future wire-format method names.
- **Inference**: single MLX runtime in the host, queued. Plugins request a
  *tier* (`small` / `medium` / `large`); the host picks the model. Default
  mapping: small → `google/gemma-4-E2B-it`, medium → `google/gemma-4-E4B-it`,
  large → `google/gemma-4-26B-A4B-it`.
- **Triggers**: event-driven (pause, save, focus change) — not continuous
  inference — to keep battery and thermals sane.
