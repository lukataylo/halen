# Architecture

One model. One permission layer. One plugin runtime. Everything you actually
use is a plugin on top of them.

Halen is a single Swift Package menubar app (`LSUIElement = true`). The
SwiftPM target graph *is* the architecture — the dependency lists in
`Package.swift` are the honesty proof:

```
HalenPluginAPI    the public plugin surface: HalenPlugin, PluginManifest,
                  Capability, PluginContext + service protocols, Event,
                  InferenceClient (tiers + priorities), the notch surface
                  types, and the shared stores (snippets, tone profiles).
                  Depends on nothing.

HalenKit          the host: model lifecycle, the priority inference queue,
                  the permission broker, the hotkey registry, the AX
                  pipeline, the notch panel manager, and the plugin runtime
                  (in-process + external stdio). Depends on HalenPluginAPI
                  (and the llama binary target) and implements its services.

Sources/Plugins/* the six bundled plugins: WritingAssistant,
                  SnippetExpander, VoiceDictation, PromptPolish, Mother,
                  NotchBoss. Each depends on HalenPluginAPI ONLY (NotchBoss
                  additionally on SwiftTerm for its embedded terminal) — a
                  first-party plugin physically cannot import host internals.

Sources/Halen     the app shell: menubar UI, settings, the permissions
                  screen, onboarding, Sparkle updater. Wires HalenKit to
                  the plugin modules.
```

## Top-level layout

```
Sources/HalenPluginAPI/   # the API — read PluginContext.swift first
Sources/HalenKit/
  Accessibility/          # AX permission, CaretObserver, TCC status model
  Events/                 # EventBus (in-process pub/sub)
  Hotkeys/                # NSEvent-backed registrar + conflict registry
  Inference/              # RouterInferenceClient, backends (Apple FM /
                          #   llama.cpp / Ollama), AsyncSemaphore,
                          #   ModelDownloader
  Notch/                  # NotchPanelManager (one panel per screen)
  Overlay/                # caret-anchored overlay windows
  PluginHosting/          # HostServices, PermissionBroker, PluginRegistry,
                          #   CalendarService
    External/             # stdio JSON-RPC plugin host (PluginHost,
                          #   PluginInstance, HostBridge, PluginRPC)
Sources/Plugins/          # WritingAssistant, SnippetExpander, VoiceDictation,
                          #   PromptPolish, Mother, NotchBoss
Sources/Halen/App/        # HalenApp, AppDelegate, AppCoordinator, menubar +
                          #   settings + permissions views, onboarding
Tests/HalenTests/         # unit tests across all targets
```

## The big picture

```
      ┌────────────────────────────────────────────────────────────────┐
      │                        AppCoordinator                          │
      │   CaretObserver (AX) ──► EventBus                              │
      │        text.pause · caret.moved · app.focused · finding.*      │
      │                             │  filtered per manifest + grants  │
      │                             ▼                                  │
      │   WritingAssistant  SnippetExpander  VoiceDictation            │
      │   PromptPolish      Mother           NotchBoss                 │
      │   external plugins (stdio JSON-RPC) ─────────────┐             │
      │                             │                    │             │
      │            PluginContext / HostBridge (capability-gated)       │
      │                             │                                  │
      │                             ▼                                  │
      │   RouterInferenceClient — priority queue per backend instance  │
      │   Apple FM · bundled llama.cpp (Gemma 4, Qwen 0.5B) · Ollama   │
      └────────────────────────────────────────────────────────────────┘
```

The arrows flow one way: the host observes the system and fans events out to
plugins; plugins act back through their capability-gated services (text
write-back, popovers, hotkeys, the notch).

## Host vs plugins

The **host** owns:

- AX capture (focused element, caret rect, debounced text snapshots).
- The shared inference runtime and both bundled model downloads.
- The permission layer (`PermissionBroker`): capability grants per plugin
  plus every macOS TCC prompt.
- The hotkey registry with process-wide conflict detection.
- Per-plugin storage roots (`~/Library/Application Support/Halen/<plugin-id>/`).
- The notch surface (`NotchPanelManager`) — one plugin at a time.
- The plugin list UI (`HalenCenterView`), the permissions screen, plugin
  lifecycle, and the external plugin host.

A **plugin** is anything conforming to `HalenPlugin`
(`Sources/HalenPluginAPI/HalenPlugin.swift`):

```swift
@MainActor
public protocol HalenPlugin: AnyObject {
    var manifest: PluginManifest { get }   // identity, events, capabilities

    func start()
    func stop()

    @MainActor func makeDetailView() -> AnyView
}
```

Identity, display metadata, observed event topics, and requested
capabilities all live in the manifest — one declaration, shown verbatim in
the permissions screen. Categories: `writing`, `voice`, `scheduling`,
`focus`, `productivity`, `agents`.

The `PluginRegistry` (`@Observable`) persists each plugin's enabled state in
`UserDefaults` under `plugin.<id>.enabled` and calls `start()` / `stop()` on
toggle. First-party plugins are registered in
`AppCoordinator.startObservers()` from a manifest + factory pair; external
plugins are discovered on disk and registered through
`ExternalPluginAdapter`, so both kinds appear in the same list with the same
toggle, capabilities, and status.

## The capability grant model

The trust model in one sentence: a plugin declares up front everything it
observes and does, the host enforces the declaration, and the user can
revoke any single capability afterwards.

- **Declaration.** `PluginManifest.capabilities` lists `Capability` raw
  values (`observe-text`, `insert-text`, `hotkeys`, `notch-overlay`,
  `process-observation`, …). Undeclared = unavailable; there is no runtime
  "ask for more".
- **Grant state.** `PermissionBroker` stores per-plugin, per-capability
  booleans in UserDefaults (`capability.<pluginId>.<capability>`). Declared
  and never touched means consented at enable time; the permissions screen
  can flip any grant off individually. The broker's
  `effectiveCapabilities(for:)` is declared ∩ not-revoked.
- **Construction-time gating.** `HostServices.makeContext(for:)` is the one
  place the gating rule lives: it builds a `PluginContext` whose services
  are nil for anything outside the effective set. A revoked capability is a
  nil service, not a runtime check the plugin could forget. Event topics are
  gated the same way — without `observe-text`, `text.pause` and
  `caret.moved` are silently removed from the plugin's subscription.
- **Restart on grant change.** When the user toggles a grant, the
  permissions screen calls `AppCoordinator.reloadPlugin(id:)`, which
  unregisters the plugin and rebuilds it from its factory with a freshly
  minted context — so a service reference never goes stale mid-flight.
- **External plugins** get the same enforcement at the RPC boundary:
  `HostBridge.dispatch` checks the caller's effective capability set on
  every gated method and returns JSON-RPC error `-32001` on a miss.
  `inference/complete` is deliberately ungated — shared access to the local
  model is the platform's baseline, and a prompt can't touch anything the
  other capabilities guard.

The broker also owns every macOS TCC prompt (Accessibility, mic, speech,
calendar, notifications, Input Monitoring, Screen Recording) so plugins
never call TCC APIs directly and one screen can show the unified status.

## The event bus

`EventBus` (`Sources/HalenKit/Events/EventBus.swift`) is a tiny pub/sub on
`AsyncStream<Event>`. Multiple subscribers each receive every event;
terminating a stream unsubscribes; slow consumers drop oldest rather than
backpressuring the host. Event cases are named as wire method names and
every payload is `Codable`:

| Case | Method | Payload |
|---|---|---|
| `textPaused`             | `text.pause`         | `appBundleId`, `appName`, `text`, `caretOffset`, `timestamp` |
| `caretMoved`             | `caret.moved`        | `appBundleId`, `rect (x,y,w,h)`, `timestamp` |
| `appFocused`             | `app.focused`        | `appBundleId`, `appName`, `timestamp` |
| `inferenceActivity`      | `inference.activity` | `phase`, `source`, `timestamp` |
| `findingDetected`        | `finding.detected`   | a plugin flagged a paragraph |
| `findingsCleared`        | `findings.cleared`   | flag cleared |
| `findingActionRequested` | `finding.action`     | user action on a finding |

Plugins can publish the plugin-sourced topics (`inference.activity`,
`finding.*`); host-sourced topics are dropped if a plugin tries to publish
them — only the host observes the system.

## AX pipeline (`CaretObserver`)

`Sources/HalenKit/Accessibility/CaretObserver.swift`. On each app switch it
re-targets an `AXObserver` at the new frontmost pid, tracks the focused
element, and turns selection/value notifications into debounced
`text.pause` snapshots (windowed to ±4 000 chars around the caret so
terminal scrollback can't flood the inference layer) plus `caret.moved`
rects. Secure text fields (password inputs) are skipped entirely at the
subscription layer.

Write-back goes the other way: `TextService.replaceRange(_:with:describedAs:)`
sets the AX selected range then writes the replacement, with a
clipboard-paste fallback for AX-hostile apps. The `describedAs` string is
announced to VoiceOver.

## Inference: the priority queue

Plugins ask for a `ModelTier` (`classifier` / `small` / `medium` / `large`)
and a `taskKind`, never a concrete model, and attach an `InferencePriority`:
`.userInitiated` for a result someone is watching for, `.background` for
speculative work.

`RouterInferenceClient` (an actor) does the routing:

1. Filters backends to those whose capability covers the request tier.
2. Sorts lexicographically: user preference order
   (`InferenceSettings.preferenceOrder`, persisted), then task affinity,
   then the backend's base priority.
3. Walks the chain, skipping backends whose cached availability probe says
   unavailable, falling through to the next on failure. (Streaming requests
   fall through only *before* the first snapshot; a mid-stream failure
   propagates rather than rewinding the consumer's view.)
4. Serializes per **backend instance** with an `AsyncSemaphore(1)`. Gates
   are keyed by instance, not backend kind, because two bundled-llama
   backends (the Qwen classifier and Gemma) hold independent model contexts
   and must not serialize against each other. Different backends run in
   parallel.

`AsyncSemaphore` is where the priorities bite: waiters are ordered
`.userInitiated` before `.background`, FIFO within a band, so a queued
background classification never runs ahead of a rewrite the user is waiting
on. There is deliberately no preemption of an in-flight generation — a
foreground request waits at most one background generation. `wait()` is
cancellation-aware, so a cancelled plugin request never leaks a permit.

Three backends ship (`InferenceBackends.makeAll()`):

| Backend | Serves tiers | Notes |
|---|---|---|
| `appleFoundationModels` | small, medium | Apple's on-device system model (macOS 26+). Zero install; prewarmed at launch. |
| `bundledLlama` | small, medium (+ classifier via the dedicated Qwen instance) | Gemma 4 E4B and Qwen 2.5 0.5B GGUFs on a bundled llama.cpp runtime, fetched by `ModelDownloader` or baked in with `BUNDLE_MODEL=1`. |
| `ollama` | small, medium, large | Local Ollama daemon over `http://localhost:11434` (endpoint user-configurable). The only backend serving `.large`. |

Plugin code only ever sees `InferenceClient`, so adding or reordering
backends is a host-only change.

## The external plugin runtime

`Sources/HalenKit/PluginHosting/External/`. Any executable speaking
newline-delimited JSON-RPC 2.0 over stdio is a plugin — the wire protocol is
unchanged from the pre-pivot bridge, and it's documented for third parties
in [PLUGINS.md](../../PLUGINS.md).

- **Discovery.** `PluginManifest.discoverAll` scans
  `~/Library/Application Support/Halen/Plugins/<plugin-id>/halen-plugin.json`.
  Manifests are validated before spawn: recognised `halenApiVersion`, safe
  id (no separators, no `..`), and a relative `executable` must resolve
  inside the plugin directory (path traversal is rejected).
- **Framing.** NDJSON, not LSP Content-Length headers: one JSON message per
  line. stdout is the RPC channel; stderr is the plugin's free-form log,
  forwarded to Halen's log.
- **Lifecycle.** `initialize` request → `notifications/initialized` →
  events as notifications → on disable/quit the polite ladder: `shutdown`
  request, `exit` notification, brief wait, SIGTERM, SIGKILL.
- **Capabilities, enforced.** Every plugin→host call goes through the single
  `HostBridge.dispatch` (plus a `hotkey/*` intercept in `PluginHost` that
  needs plugin identity to route `hotkey.fired` back). Gated methods check
  the caller's effective capability set and fail with `-32001` when the
  capability is undeclared or revoked. Event topics are filtered to the
  manifest's `events` list before they reach the plugin's stdin.
- **Crash isolation.** One subprocess per plugin; a segfaulting plugin
  takes nothing else down. There is no automatic restart yet — a crashed
  plugin stays dead until next launch.

There is deliberately **no OS sandbox** around external plugins: an external
plugin is a process running as you, and the manifest is enforced at the RPC
boundary. Install plugins you've read.

## Storage

Each plugin gets a private directory at
`~/Library/Application Support/Halen/<plugin-id>/` via
`PluginContext.storage` (`readJSON`/`writeJSON`, atomic, pretty-printed,
sorted keys — hand-editable). Concrete layout:

| Path (under `~/Library/Application Support/Halen/`) | Owner | Contents |
|---|---|---|
| `typos.json` | Writing Assistant (TypoStore) | Learned + seeded typo corrections. Top-level path kept for pre-pivot compatibility. |
| `com.halen.writing-assistant/style-rules.json` | Writing Assistant (preferred terms) | Literal / regex / prohibition rules. |
| `com.halen.writing-assistant/sentiment-rules.json` | Writing Assistant (tone) | Built-in + custom tone rules. |
| `com.halen.writing-assistant/clarity-rules.json` | Writing Assistant (clarity) | Clarity rules. |
| `com.halen.writing-assistant/approved.json` | Writing Assistant (tone) | SHA-256 fingerprints of drafts marked "Looks fine". |
| `com.halen.snippet-expander/snippets.json` | Snippet library | Built-in + custom snippets (path unchanged). |
| `com.halen.tone-profiles/profiles.json` | AppToneProfileStore (host) | Per-app target tone, shared via the `tone-profiles` capability. |
| `com.halen.mother/config.json`, `state.json` | Mother | Rulebook and ledger — schemas unchanged from the Python-era plugin. |
| `Plugins/<plugin-id>/` | external plugins | Self-contained install dirs: manifest + executable + local data. |

The Writing Assistant engines share the plugin's single storage directory
with one file per engine (the per-engine *directories* of the old
one-plugin-per-engine era are gone; `typos.json` and `snippets.json` keep
their original paths so user data carries over without migration). Built-in
seed entries (typos, snippets, rules) are re-merged on every launch so new
seeds ship without overwriting user customisations.

Notch Boss additionally keeps its NotchBar-inherited state under
`~/.notchbar/` (hook script, approval socket, coordination state) — see
[its plugin doc](plugins/notch-boss.md).

## App entry & lifecycle

`Sources/Halen/App/HalenApp.swift` is the SwiftUI `@main`; `AppDelegate`
owns one `AppCoordinator`, which:

1. Starts both model downloads/prewarms in the background and polls
   `AXIsProcessTrusted()` until Accessibility is granted.
2. Starts `CaretObserver`, the overlay, and builds `HostServices` (the
   context factory) around the broker, router, and shared stores.
3. Registers the six first-party plugins (manifest + factory each),
   discovers external plugins, and starts the event dispatcher. If a
   NotchBar install is detected (`~/.notchbar` exists) and the Notch Boss
   toggle was never touched, Notch Boss defaults to on.
4. Presents onboarding on first run.
5. On quit, runs the async shutdown ladder for external plugin processes,
   then `stop()`s every plugin so hotkeys, AX observers, and panels unwind
   cleanly.

## What's deliberately not here

- **No telemetry.** No analytics, no remote logging, no crash uploads. Logs
  go to stderr and the unified system log; user text in logs is redacted to
  an unforgeable fingerprint (`Log.redact`).
- **No cloud fallback.** Every prompt is served on-device; the router never
  reaches out to a remote model.
- **No plugin store, no plugin signing, no update channel for plugins.**
  The plugin directory is a folder.
- **No streaming over the external RPC** (`inference/complete` blocks;
  first-party plugins get streaming through the Swift API).
- **No background daemon.** Quitting the menubar quits everything.
