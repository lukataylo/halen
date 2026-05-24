# Architecture

One AX pipeline. One event bus. One inference router. Many plugins.

That's the whole shape. A single Swift Package menubar app
(`LSUIElement = true`) hosts the first-party plugins in-process and
spawns third-party plugins as JSON-RPC subprocesses over stdio. ~13k
lines of Swift, 168 unit tests under `Tests/HalenTests/`. Everything
flows through three seams: AX → events → inference. Plugins plug into
the middle one.

## Top-level layout

```
Sources/Halen/
  App/               # SwiftUI App, AppDelegate, AppCoordinator, MenuBarExtra UI
  Accessibility/     # AX permission, caret observer, AX attribute helpers
  Events/            # In-process pub/sub + typed event payloads
  Inference/         # RouterInferenceClient + protocol, ModelTier, backends
                     #   (Apple FM / llama.cpp / Ollama), ModelDownloader
  Overlay/           # Caret-anchored NSWindow shell
  Plugins/           # HalenPlugin protocol, HalenServices DI container, registry,
                     #   External/ — out-of-process plugin host + WebSocket bridge
  Features/          # The ten in-process first-party plugins
                     #   (out-of-process plugins live in /plugins at the repo root)
  Support/           # Logging, string diff, hashing, paragraph classifier
```

## The big picture

```
       ┌──────────────────────────────────────────────────────────────┐
       │                          AppCoordinator                      │
       │  ┌────────────────────────────────────────────────────────┐  │
       │  │            CaretObserver (AX → events)                 │  │
       │  └────────────────────┬───────────────────────────────────┘  │
       │                       │ publishes                            │
       │                       ▼                                      │
       │  ┌────────────────────────────────────────────────────────┐  │
       │  │                    EventBus                            │  │
       │  │  text.pause · caret.moved · app.focused · …            │  │
       │  └─┬─────────────┬─────────────┬─────────────┬────────────┘  │
       │    │             │             │             │               │
       │    ▼             ▼             ▼             ▼               │
       │  AskHalen  TypoFixer  SentimentGuard  SnippetExpander        │
       │  ClarityChecker  VoiceDictation  Autocomplete  StyleGuide    │
       │  EmailReply  ToneProfiles                                    │
       │                       │            BurnoutCopilot ─┐         │
       │                       │            MeetingPrep    ─┤ stdio   │
       │                       │ async calls               ─┘ JSON-RPC│
       │                       ▼                                      │
       │  ┌────────────────────────────────────────────────────────┐  │
       │  │              RouterInferenceClient                     │  │
       │  │   routes per request, falls through on failure:        │  │
       │  │   Apple FM · bundled Gemma 4 (llama.cpp) · Ollama      │  │
       │  └────────────────────────────────────────────────────────┘  │
       └──────────────────────────────────────────────────────────────┘
```

The arrows flow one way: AX events fan out to plugins; plugins write back
through `CaretObserver.replaceRange(_:with:)` or through their own UI panels.

## Host vs plugins

The **host** owns:

- AX capture (focused element, caret rect, debounced text snapshots).
- The shared inference runtime (`RouterInferenceClient`, which serializes
  per-backend requests and falls through across Apple FM / llama.cpp / Ollama).
- Per-plugin storage roots (`~/Library/Application Support/Halen/<pluginId>/`).
- Permission UI (Accessibility, Calendar, Mic, Speech, Notifications).
- The marketplace UI (`HalenCenterView`) and plugin lifecycle.
- The out-of-process plugin host (`Plugins/External/`) and the loopback
  WebSocket bridge the browser extension connects to.

A **plugin** is anything conforming to `HalenPlugin`:

```swift
@MainActor
protocol HalenPlugin: AnyObject {
    var id: String { get }               // "com.halen.typo-fixer"
    var name: String { get }
    var summary: String { get }
    var icon: String { get }             // SF Symbol
    var category: PluginCategory { get }

    func start()
    func stop()

    @MainActor func makeDetailView() -> AnyView
}
```

Categories: `writing`, `voice`, `scheduling`, `focus`, `productivity`.

Ten in-process plugins ship as Swift classes wired into
`AppCoordinator.startObservers()`: `AskHalen`, `TypoFixer`,
`SentimentGuard`, `SnippetExpander`, `ClarityChecker`, `VoiceDictation`,
`Autocomplete`, `StyleGuide`, `EmailReply`, `ToneProfiles`. The
`PluginRegistry` (`@Observable`) persists each plugin's enabled state in
`UserDefaults` under the key `plugin.<id>.enabled` and calls `start()` /
`stop()` on toggle. Default-off plugins (Voice, Autocomplete, StyleGuide,
EmailReply, ToneProfiles) opt in via onboarding.

Out-of-process plugins — `BurnoutCopilot` and `MeetingPrep` ship in this
repo under `plugins/`; users can also drop their own into
`~/Library/Application Support/Halen/Plugins/` — are registered alongside
the in-process set via `ExternalPluginAdapter`. They speak the same
`HalenPlugin` event surface over NDJSON-on-stdio.

## The DI container: `HalenServices`

Everything a plugin needs from the host arrives through a single struct:

```swift
@MainActor
struct HalenServices {
    let eventBus: EventBus
    let inference: InferenceClient
    let caretObserver: CaretObserver
    let appSupportDir: URL

    func storageDirectory(for pluginId: String) -> URL
}
```

This is deliberately narrow. When `HalenServices` becomes a JSON-RPC client
in M4, every surface here has a clean mapping (`eventBus.subscribe()` →
`subscribe` method; `inference.complete(...)` → `inference.complete`
method; `caretObserver.replaceRange(...)` → `caret.replace` method).

## The event bus

`EventBus` is a tiny pub/sub on top of `AsyncStream<Event>`:

```swift
final class EventBus: @unchecked Sendable {
    func subscribe() -> AsyncStream<Event>
    func publish(_ event: Event)
}
```

Multiple subscribers each receive every published event. Termination of a
stream auto-unsubscribes. Each `Event` case is named to be a future JSON-RPC
method name and each payload is `Codable`:

| Case | Method | Payload |
|---|---|---|
| `textPaused`        | `text.pause`        | `appBundleId`, `appName`, `text`, `caretOffset`, `timestamp` |
| `caretMoved`        | `caret.moved`       | `appBundleId`, `rect (x,y,w,h)`, `timestamp` |
| `appFocused`        | `app.focused`       | `appBundleId`, `appName`, `timestamp` |
| `inferenceActivity` | `inference.activity`| `phase (started/finished)`, `source`, `anchor?`, `timestamp` |

The `text.pause` event is the workhorse — every writing plugin keys off it.

## AX pipeline (`CaretObserver`)

Defined in `Sources/Halen/Accessibility/CaretObserver.swift`. Responsibilities:

1. **App switching.** Subscribes to `NSWorkspace.didActivateApplicationNotification`.
   On each switch it tears down the previous `AXObserver` and creates a new
   one for the new pid (skips itself: bundle id `com.dadiani.halen`).
2. **Focused element tracking.** Registers
   `kAXFocusedUIElementChangedNotification` on the app element. When the
   focused element changes, it unregisters
   `kAXSelectedTextChangedNotification` + `kAXValueChangedNotification` on
   the old element and registers them on the new one.
3. **Debounced text snapshots.** Selection / value changes schedule a 400 ms
   debounce. When it fires, the observer reads `kAXValueAttribute` (the full
   text) and `kAXSelectedTextRangeAttribute` (caret offset), then publishes
   `text.pause`. Payloads are capped at **8 000 chars windowed around the
   caret** (`windowAroundCaret(text:offset:radius:)`) so terminal scrollback
   never DDoSes the inference layer.
4. **Caret rect emission.** On selection change, it calls
   `kAXBoundsForRangeParameterizedAttribute` for a zero-length range at the
   caret to get the screen rect. Converted from AX (top-left) to Cocoa
   (bottom-left) coordinates with `axRectToCocoa`.

Bridging the C callback to Swift's actor world uses
`MainActor.assumeIsolated`:

```swift
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let observer = Unmanaged<CaretObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        observer.handleNotification(element: element, name: name)
    }
}
```

### AX write-back

The single public mutation API:

```swift
@discardableResult
func replaceRange(_ range: NSRange, with replacement: String) -> Bool
```

Sets `kAXSelectedTextRangeAttribute` to the target range, then writes
`kAXSelectedTextAttribute` with the replacement. Returns `false` for
elements that don't honour AX writes — most Electron / web text fields and
terminals. Used by `TypoFixer`, `SnippetExpander`, `VoiceDictation`, and
`AskHalen` (which falls back to a clipboard + ⌘V paste when the AX write
fails).

## Inference layer

`InferenceClient` is a one-method protocol:

```swift
protocol InferenceClient: Sendable {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse
}

struct InferenceRequest: Sendable {
    let prompt: String
    let tier: ModelTier
    let maxTokens: Int        // default 256
    let temperature: Double   // default 0.2
    let stop: [String]
    let taskKind: InferenceTaskKind   // .classification | .generation, default .generation
}
```

Plugins ask for a `ModelTier` (`small` / `medium` / `large`) and a
`taskKind`, never a concrete model. The concrete `InferenceClient` is
`RouterInferenceClient`, which holds a set of `InferenceBackend`s and, for
each request:

1. Filters to backends whose `capability.servesTiers` covers the request tier.
2. Sorts by a lexicographic key — user preference order first
   (`InferenceSettings.preferenceOrder`, persisted), then task-affinity
   (`capability.strongAt`), then the backend's `basePriority`.
3. Walks the resulting chain, skipping any backend whose cached availability
   probe says unavailable, and falls through to the next on failure.
4. Serializes same-backend requests with a per-backend `AsyncSemaphore(1)`;
   different backends still run in parallel.

Three backends ship (`InferenceBackends.makeAll()`):

| Backend (`BackendKind`)  | Serves tiers      | Notes |
|--------------------------|-------------------|-------|
| `appleFoundationModels`  | small, medium     | Apple's on-device system model via the Foundation Models framework, macOS 26+. Zero install; prewarmed at launch. |
| `bundledLlama`           | small, medium     | Gemma 4 E4B (`IQ4_XS` GGUF) on a bundled llama.cpp runtime. Model fetched on first use by `ModelDownloader`, or baked into the `.app` with `BUNDLE_MODEL=1`. |
| `ollama`                 | small, medium, large | Local Ollama daemon (`OllamaBackend` → `OllamaInferenceClient`). The only backend serving `.large`. Endpoint configurable via `OllamaSettings`. |

The default preference order is Apple FM → bundled llama.cpp → Ollama; the
user can reorder it in Settings → Inference.

The Ollama client POSTs to `http://localhost:11434/api/chat` (or the
configured endpoint) with `stream: false`; tier maps to `gemma4:e2b` /
`gemma4:e4b` / `gemma4:26b`. Plugin code only ever sees `InferenceClient`, so
adding or reordering backends is a host-only change.

## Storage

Each plugin gets a directory under
`~/Library/Application Support/Halen/<pluginId>/` via
`HalenServices.storageDirectory(for:)`. Concrete examples:

| File | Owner | Contents |
|---|---|---|
| `Halen/typos.json`                                 | TypoStore (top-level)    | `{ version, entries: { typo → { correction, observations, firstSeen, lastSeen } } }` |
| `Halen/com.halen.sentiment-guard/rules.json`       | SentimentRulesStore      | Built-in + custom tone rules |
| `Halen/com.halen.sentiment-guard/approved.json`    | SentimentGuard           | SHA-256 hashes of texts the user marked "Looks fine" |
| `Halen/com.halen.snippet-expander/snippets.json`   | SnippetStore             | Built-in + custom snippets |
| `Halen/com.halen.meeting-prep/processed.json`      | MeetingPrep              | EventKit identifiers already briefed |

All files are pretty-printed JSON with sorted keys. They are hand-editable;
the host re-merges built-ins on every launch so newly-shipped seed entries
appear without overwriting user customisations.

## App entry & lifecycle

`Sources/Halen/App/HalenApp.swift` is the SwiftUI `@main`. It hosts an
`NSApplicationDelegateAdaptor` (`AppDelegate`) that owns one
`AppCoordinator`. The coordinator:

1. Polls `AXIsProcessTrusted()` every second until the user grants
   Accessibility.
2. Once granted, starts `CaretObserver`, the overlay window, and the plugin
   registry.
3. Registers all ten in-process first-party plugins with their stored enabled
   state (or their default-on/off if never set), discovers any out-of-process
   plugins, and starts the WebSocket bridge if it's enabled in Settings.
4. On quit, runs the async shutdown ladder for out-of-process plugins, then
   calls `plugin.stop()` for everything so hotkeys, AX observers, and
   floating panels unwind cleanly.

The menubar UI itself is `HalenCenterView`, a `MenuBarExtra` popover with
category sections, per-plugin toggles, a footer with Accessibility shortcut
and Quit, and a slide-in detail view per plugin.

## What's deliberately not here yet

- **No telemetry.** No analytics, no remote logging, no automatic crash
  reporter. Logs go to stderr and the unified system log only.
- **No cloud fallback.** Every prompt is served on-device. If no backend is
  available, plugins that need inference surface an actionable error and log
  a warning — the router never reaches out to a remote model.
- **No background daemon.** The app is a regular `NSApplication`; quitting
  the menubar quits everything.
