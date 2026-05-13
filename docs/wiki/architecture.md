# Architecture

Halen is a single Swift Package menubar app (`LSUIElement = true`) that hosts
plugins in-process today and is designed to extract them to out-of-process
JSON-RPC subprocesses in a later milestone. The whole codebase is roughly
4k lines of Swift.

## Top-level layout

```
Sources/Halen/
  App/               # SwiftUI App, AppDelegate, AppCoordinator, MenuBarExtra UI
  Accessibility/     # AX permission, caret observer, AX attribute helpers
  Events/            # In-process pub/sub + typed event payloads
  Inference/         # InferenceClient protocol, ModelTier, Ollama client, stub
  Overlay/           # Caret-anchored NSWindow shell
  Plugins/           # HalenPlugin protocol, HalenServices DI container, registry
  Features/          # The six first-party plugins
  Support/           # Logging, string diff
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
       │  TypoFixer  SentimentGuard  VoiceDictation  SnippetExpander  │
       │                    BurnoutCopilot   MeetingPrep              │
       │                       │           │                          │
       │                       │           │ async calls              │
       │                       ▼           ▼                          │
       │  ┌────────────────────────────────────────────────────────┐  │
       │  │              OllamaInferenceClient                     │  │
       │  │   (HTTP → http://localhost:11434, gemma4:e2b / e4b)    │  │
       │  └────────────────────────────────────────────────────────┘  │
       └──────────────────────────────────────────────────────────────┘
```

The arrows flow one way: AX events fan out to plugins; plugins write back
through `CaretObserver.replaceRange(_:with:)` or through their own UI panels.

## Host vs plugins

The **host** owns:

- AX capture (focused element, caret rect, debounced text snapshots).
- The shared inference runtime (Ollama HTTP client, queued).
- Per-plugin storage roots (`~/Library/Application Support/Halen/<pluginId>/`).
- Permission UI (Accessibility, Calendar, Mic, Speech, Notifications).
- The marketplace UI (`HalenCenterView`) and plugin lifecycle.

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

Today plugins are Swift classes wired into `AppCoordinator.startObservers()`.
Six of them ship: `TypoFixer`, `SentimentGuard`, `VoiceDictation`,
`SnippetExpander`, `BurnoutCopilot`, `MeetingPrep`. The
`PluginRegistry` (`@Observable`) persists each plugin's enabled state in
`UserDefaults` under the key `plugin.<id>.enabled` and calls `start()` /
`stop()` on toggle.

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
| `textPaused`       | `text.pause`       | `appBundleId`, `appName`, `text`, `caretOffset`, `timestamp` |
| `textSaved`        | `text.save`        | `appBundleId`, `appName`, `text`, `timestamp` |
| `caretMoved`       | `caret.moved`      | `appBundleId`, `rect (x,y,w,h)`, `timestamp` |
| `appFocused`       | `app.focused`      | `appBundleId`, `appName`, `timestamp` |
| `clipboardChanged` | `clipboard.changed`| `textPreview`, `timestamp` |

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
terminals. Used by `TypoFixer`, `SnippetExpander`, and `VoiceDictation`.

## Inference layer

`InferenceClient` is a one-method protocol:

```swift
protocol InferenceClient: Sendable {
    func complete(_ request: InferenceRequest) async throws -> InferenceResponse
}

struct InferenceRequest: Sendable {
    var prompt: String
    var tier: ModelTier
    var maxTokens: Int = 256
    var temperature: Double = 0.2
    var stop: [String] = []
}
```

`ModelTier` (`small` / `medium` / `large`) is what plugins ask for. The
default mapping in `OllamaInferenceClient`:

| Tier   | Model name      | Where used |
|--------|-----------------|------------|
| small  | `gemma4:e2b`    | Burnout tone yes/no classification (4 tokens) |
| medium | `gemma4:e4b`    | Sentiment Guard classify + rephrase, Snippet AI snippets, Meeting Prep briefings |
| large  | `gemma4:26b`    | Reserved for future workstation paths |

The client POSTs to `http://localhost:11434/api/chat` with `stream: false`.
Timeouts: 60 s request, 120 s resource. Plugin code only sees
`InferenceClient`, so swapping Ollama for MLX/llama.cpp later is a host-only
change.

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
3. Registers all six first-party plugins with their stored enabled state.
4. On quit, calls `plugin.stop()` for everything so hotkeys, AX observers,
   and floating panels unwind cleanly.

The menubar UI itself is `HalenCenterView`, a `MenuBarExtra` popover with
category sections, per-plugin toggles, a footer with Accessibility shortcut
and Quit, and a slide-in detail view per plugin.

## What's deliberately not here yet

- **No telemetry.** No analytics, no remote logging, no automatic crash
  reporter. Logs go to stderr and the unified system log only.
- **No cloud fallback.** Every prompt hits localhost. If Ollama isn't
  running, plugins that need inference fail silently and log a warning.
- **No background daemon.** The app is a regular `NSApplication`; quitting
  the menubar quits everything.
