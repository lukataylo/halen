# Burnout Copilot

> Plugin id: `com.halen.burnout-copilot` · Category: Focus · Code:
> [`plugins/burnout-copilot/`](../../../plugins/burnout-copilot/)
>
> **Runs out-of-process** as a JSON-RPC plugin over stdio (extracted in
> milestone M2.4). The menubar app brokers `text.pause` / `app.focused` /
> `calendar.*` events to it and proxies the UI prompts it asks for. Same
> `HalenPlugin` event surface in-process plugins use — just over a
> socket. See [plugins/README.md](../../../plugins/README.md) for the
> protocol.

Three signals, 2-of-3 trip rule, one-button "Take 10?" popup. The signals
come from the event bus (focus changes), local Gemma 4 (tone), and
EventKit (calendar density).

## The three signals

Defined in
[`BurnoutSignals.swift`](../../../Sources/Halen/Features/BurnoutCopilot/BurnoutSignals.swift).

### Signal A — Distraction app time (`DistractionTimeTracker`)

A rolling **2-hour window** of focus segments from `app.focused` events.
Each segment is `{ bundleId, start, end }`. The current segment's
contribution is computed live against `Date()` so the count is always up
to date.

The bundle id allow-list is hardcoded:

```swift
static let distractionBundles: Set<String> = [
    "com.tinyspeck.slackmacgap",     // Slack
    "com.hnc.Discord",               // Discord
    "com.twitter.twitter-mac",       // Twitter classic
    "com.atebits.Tweetie2",          // Twitterrific
    "ru.keepcoder.Telegram",         // Telegram
    "com.reddit.reddit",
    "com.zhiliaoapp.musically",      // TikTok
    "com.facebook.archon",           // FB / Messenger
    "com.colliderli.iina",           // streaming
    "com.netflix.Netflix",
]
```

Tripped when `distractionMinutesInWindow >= 90`.

### Signal B — Tone trend (`ToneTrendTracker`)

A rolling window of the **last 10 tone classifications**, each `.calm` or
`.sharp`. Records are added by `BurnoutCopilot.classifyTone(_:caretOffset:)`,
which sends paused text (windowed to ~800 chars, only if > 60 chars) to the
`.small` inference tier for a yes/no:

```swift
let prompt = """
Is the tone of the following text irritated, sharp, or hostile? Reply with only "yes" or "no", lowercase.

Text: \"\"\"\(paragraph)\"\"\"
"""
let request = InferenceRequest(prompt: prompt, tier: .small, maxTokens: 16,
                               temperature: 0.1, taskKind: .classification)
```

Tripped when `sharpCount >= 3` in the last 10 samples.

### Signal C — Calendar density (`CalendarDensityTracker`)

EventKit query for non-all-day events in the next **4 hours**. Two
sub-conditions either of which trips the signal:

- `nextFourHourEvents >= 3` (the `calendarDenseThreshold`), or
- `hasBackToBackSoon = true` — any two consecutive events in the next
  30 min with less than a 5-minute gap.

Uses `EKEventStore.requestFullAccessToEvents()` on macOS 14+ with a
fallback to `requestAccess(to: .event)` for older systems. `hasAccess` is
exposed to the detail view so the user can see whether to grant calendar
permission.

## Evaluation loop

In `BurnoutCopilot`:

```swift
let signalA = state.distractionMinutes >= state.distractionThreshold   // 90 min
let signalB = state.toneSharpCount >= state.toneTripThreshold          // 3
let signalC = state.nextFourHourEvents >= state.calendarTripThreshold  // 3
           || state.hasBackToBackSoon

let tripped = [signalA, signalB, signalC].filter { $0 }.count
if tripped >= 2 || force {
    showPopup(...)
    cooldownUntil = Date().addingTimeInterval(30 * 60)
}
```

The evaluator fires on every `app.focused` event and on a **5-minute
heartbeat task** so the rolling windows decay in real time even if the
user isn't switching apps. After firing, a **30-minute cooldown** prevents
repeated nudges.

## The popup

Borderless, floating `NSPanel` (360 × 220) anchored to the bottom-right of
the main screen. The message string is composed from the tripped signals,
joined by `·`:

> 92min in distraction apps · recent writing reads sharp · 4 meetings in the next 4h

If the detail view's "Force evaluate" button is used and nothing has
actually tripped, the popup shows a demo string instead:

> Demo trigger. A real suggestion fires when 2 of 3 signals trip — give it time or rack up some Slack minutes first.

`BurnoutCopilotPopup` (in
[`BurnoutCopilotViews.swift`](../../../Sources/Halen/Features/BurnoutCopilot/BurnoutCopilotViews.swift))
renders the headline, the signal breakdown, and two buttons:

- **Block it in** — calls `acceptBreak()`
- Dismiss (`×`) — closes the panel

## "Block it in": calendar + Shortcuts

`acceptBreak()` does two things, both fire-and-forget:

1. **Create a calendar event.** `CalendarDensityTracker.createBreakEvent()`
   inserts an `EKEvent` titled `🌿 Halen break` into the default new-event
   calendar, starting now, lasting **10 minutes**:

   ```swift
   let ev = EKEvent(eventStore: store)
   ev.calendar = store.defaultCalendarForNewEvents
   ev.title = "🌿 Halen break"
   ev.startDate = now
   ev.endDate = now.addingTimeInterval(10 * 60)
   try store.save(ev, span: .thisEvent, commit: true)
   ```

2. **Trigger a "Halen Focus" Shortcut.** Runs:

   ```bash
   osascript -e 'tell application "Shortcuts Events" to run shortcut "Halen Focus"'
   ```

   If the user has created a Shortcut by that exact name (typically: turn
   on a Focus mode, mute Slack, pause music), it runs. If they haven't,
   `osascript` silently fails and Burnout logs at debug level. **No UI is
   imposed for the missing case** — it's a soft contract the user opts
   into.

## Detail view

`BurnoutCopilotDetailView` exposes:

- Current distraction minutes vs threshold
- Tone sample dots (last 10) with sharp count
- Next-4h event count + next event title/time
- "Force evaluate now" button — re-runs the snapshot and forces the popup

## State

`BurnoutState` is `@Observable` and tracks all three signals plus
`signalA/B/C` flags and a `lastEvaluated` timestamp so the detail view
shows live values.
