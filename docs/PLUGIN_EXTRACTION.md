# Plugin extraction plan

How the five default-off plugins move from in-process Swift to
out-of-process JSON-RPC. Multi-session work — this doc is the
source-of-truth for what's done and what's queued.

## Why extract

Three reasons to move plugins out of the menubar binary:

1. **Independent update cadence.** Bug-fix a single plugin without
   shipping a whole new .app.
2. **Smaller bundle.** Each in-process plugin compiles into the menubar
   binary; default-off plugins are dead weight for users who never turn
   them on.
3. **Same trust surface as third-party plugins.** Forces the host's
   `HostBridge` API to be complete enough that user-authored plugins
   can do everything first-party ones can. If we wouldn't ship a
   capability to a third party, we shouldn't be using it in-process
   either.

## What's extracted, what isn't

| Plugin | Status | Lives at | Blocker |
|---|---|---|---|
| **StyleGuide** | First-cut external version ships in v0.2.0 alongside the in-process one | [`plugins/style-guide/`](../plugins/style-guide/) | Auto-install pattern not built yet; in-process registration not removed |
| **EmailReply** | First-cut external version ships in v0.2.0 alongside the in-process one. New `hotkey/register` host RPC method underpins it | [`plugins/email-reply/`](../plugins/email-reply/) | Same auto-install + in-process-removal cutover as StyleGuide; also needs `clipboard/set` and a richer `ax/readSelection` to match in-process UX exactly |
| **ToneProfiles** | First-cut external version ships in v0.2.0 alongside the in-process one. New `profile/{get,set,list}ToneProfile` host RPC methods underpin it | [`plugins/tone-profiles/`](../plugins/tone-profiles/) | Editor only — host still owns the store, in-process Sentiment Guard / Clarity Checker continue reading the host service. Same auto-install cutover |
| **VoiceDictation** | In-process only, likely stays | — | AVAudioEngine + SFSpeechRecognizer need framework access; would require a Swift-binary plugin and TCC inheritance work |

## The pattern

External plugins are subdirectories of `plugins/` (in the repo) and
`~/Library/Application Support/Halen/Plugins/` (on users' machines).
Each contains:

```
plugins/<id-slug>/
├── halen-plugin.json   # manifest
├── plugin.py           # NDJSON-over-stdio main loop
└── README.md           # per-plugin doc
```

The manifest format and the host-side JSON-RPC methods live in
[`plugins/README.md`](../plugins/README.md). The host-side spawn /
event-dispatch / RPC-handling code lives in
`Sources/Halen/Plugins/External/`.

`burnout-copilot` and `meeting-prep` were the first extractions (milestones
M2.3 and M2.4); both were later removed as unused. The surviving reference
implementations are `reasoning-compactor` and `mother` — new extractions
should mirror their JSON-RPC plumbing (see the `_send` / `call` / `_resolve`
helpers, identical across all the out-of-process plugins).

## What StyleGuide proved

StyleGuide is the simplest extraction target because it needs no new
host methods:

- Subscribes to `event/text.pause`
- Calls `ax/readSelection` to inspect the live field
- Calls `ax/replaceRange` to write back
- Calls `ui/prompt` to ask the user before replacing

Everything's already in the protocol as of v0.2.0. The first cut
([`plugins/style-guide/plugin.py`](../plugins/style-guide/plugin.py))
mirrors the in-process Swift implementation's matching semantics,
defaults, and dedup logic. The UX regression is real: the native
caret-anchored `FindingsPopover` becomes a system modal via
`ui/prompt`.

## What the next extractions need

### EmailReply — `hotkey/register` ✅ shipped in v0.2.0

EmailReply uses a Carbon hotkey (⌃⌥E). `hotkey/register` and
`hotkey/unregister` are now host RPC methods — the host owns the Carbon
registration and pushes `event/hotkey.fired` notifications back to the
registering plugin.

```jsonc
{ "method": "hotkey/register",
  "params": { "keyCode": int, "modifiers": int, "id": "string" },
  "result": { "ok": true } }

{ "method": "hotkey/unregister",
  "params": { "id": "string" },
  "result": { "ok": true } }

// Host → plugin notification when the hotkey fires:
{ "method": "event/hotkey.fired",
  "params": { "payload": { "id": "string", "timestamp": number } } }
```

The plugin must list `hotkey.fired` in its manifest's `events` array to
actually receive the notification. Hotkeys are unregistered
automatically when the plugin process terminates — a misbehaving plugin
can't leave a stale Carbon registration around. See
[`plugins/README.md`](../plugins/README.md) for the protocol details
and [`plugins/email-reply/`](../plugins/email-reply/) for a worked
example.

### Finding events for external plugins

An external writing plugin may want to react to other plugins' findings
(e.g. suppress its own suggestions while a paragraph is flagged). The host
exposes `event/finding.detected` and `event/finding.cleared` topics that
plugins can declare in their manifest; the host fans them out the same way
it does `text.pause`. The opaque-shape payload (source plugin id, severity,
summary) goes over the wire unchanged.

### ToneProfiles — `profile/getToneProfile`

The host already owns `AppToneProfileStore` as `HalenServices.toneProfiles`.
In-process plugins call `services.toneProfiles.profile(for: bundleId)`
directly. For an external ToneProfiles plugin to own the data, other
plugins (SentimentGuard, ClarityChecker) need an RPC to read it:

```jsonc
{ "method": "profile/getToneProfile",
  "params": { "bundleId": "com.apple.iChat" },
  "result": { "tone": "casual", "promptClause": "The user writes…" } }
```

The host either delegates to the running ToneProfiles plugin, or keeps
owning the store and ToneProfiles becomes purely an editor — the
latter is simpler and matches today's "host owns the data" reality.

### VoiceDictation — likely stays in-process

AVAudioEngine + SFSpeechRecognizer need direct framework access. Three
options:

1. **Swift-binary plugin** — compile a separate Swift CLI that uses
   AVFoundation + Speech directly, ship it in the .app bundle, declare
   the right entitlements. Needs TCC-inheritance verification (does a
   subprocess of a privileged parent inherit mic access? answer:
   sometimes, depends on `posix_spawn` vs `fork`).
2. **Hybrid: hotkey + AX in external, audio capture stays in host** —
   move just the hotkey + transcript-insert UI out; audio engine and
   speech recogniser stay in-process and stream transcripts to the
   plugin via a new `event/voice.transcript` topic. Lots of moving
   parts for an unclear win.
3. **Leave in-process.** Voice Dictation is a default-off, low-traffic
   feature; the savings from extracting it are small.

Recommendation: pick #3 until #1 has a clear ship path.

## Migration UX for v0.3.0

When in-process StyleGuide is removed, existing users who had it on
must keep getting StyleGuide functionality. Plan:

1. Bundle the contents of `plugins/style-guide/` (and other extracted
   plugins) into the .app at `Contents/Resources/BundledPlugins/`.
2. On first launch under a new version, `AppCoordinator` copies any
   bundled plugin not already in
   `~/Library/Application Support/Halen/Plugins/` to that directory,
   preserving the user's existing customisations (`rules.json`,
   per-plugin defaults).
3. The user's previously-enabled state for the plugin id is honoured
   by `PluginRegistry.readPersistedEnabled` — no extra wiring needed.

This is the same shape as Xcode's "ship a template, copy it to user
data on first launch" pattern. Implement once; reuse for every
subsequent extraction.

## Out-of-scope (still in-process forever)

- **AskHalen** — needs the global `⌃H` hotkey and the focused-field
  capture race condition handling. The hotkey could move to a plugin,
  but the palette UI is tightly coupled to NSPanel + caret anchoring,
  which doesn't translate cleanly across the RPC boundary.
- **TypoFixer** — the typo-learning loop watches text snapshots
  diff-by-diff; each `text.pause` carries enough text that the RPC
  round-trip adds real latency. Stays in-process for the same reason
  the AX layer does.
- **SentimentGuard** — same reason as TypoFixer plus it owns the
  shared overlay's findings-detection signal that other plugins
  consume.
- **SnippetExpander** — owns the `;tag` trigger detection + the
  ⌃⌥R hotkey + the streaming write-back; the trigger scan runs on
  every `text.pause` and would slow under RPC.
- **ClarityChecker** — same shape as SentimentGuard.
