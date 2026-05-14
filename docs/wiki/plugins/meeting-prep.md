# Meeting Prep

> Plugin id: `com.halen.meeting-prep` · Category: Scheduling · Code:
> [`Sources/Halen/Features/MeetingPrep/`](../../../Sources/Halen/Features/MeetingPrep/)

Fifteen minutes before each upcoming calendar event, Gemma 4 E4B writes a
5-bullet briefing, drops it on the clipboard, and posts a notification.
Each event is briefed exactly once.

## Polling loop

`MeetingPrep.start()` kicks off an async task that runs forever:

```swift
pollTask = Task { @MainActor [weak self] in
    while !Task.isCancelled {
        await self?.pollAndBrief()
        try? await Task.sleep(for: .seconds(5 * 60))
    }
}
```

Every **5 minutes** it queries EventKit for the next hour, filters out
all-day events, sorts by start date, and for each event checks:

```swift
let minutesAway = start.timeIntervalSince(now) / 60
guard minutesAway >= 13, minutesAway <= 17 else { continue }
guard !processedIds.contains(event.eventIdentifier ?? "") else { continue }
await brief(event: event)
```

The **13–17 minute window** is wider than 15 minutes to forgive jitter in
the polling cadence — a 5-min poll could miss a 14:55 event if it landed
at 14:38 and 14:43. With a 4-minute window, two consecutive polls will
always catch it.

## The briefing prompt

`MeetingPrep.brief(event:force:)` reads the event title, attendee names,
and notes:

```swift
let prompt = """
Write a 5-bullet meeting briefing. Output only the bullets, no preamble or trailing text.
Cover: what's likely on the agenda; suggested questions to ask; things to bring up; prep needed; tone cue.

Meeting: \(title)
Attendees: \(attendees.isEmpty ? "(none listed)" : attendees)
Description: \(description.isEmpty ? "(none)" : description)
"""

let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 400, temperature: 0.4)
```

Gemma 4 E4B at `temperature: 0.4`, `maxTokens: 400`. The prompt is
deliberately rigid about output format ("Output only the bullets, no
preamble") so the result can land directly on the clipboard.

## Side effects on success

Three things happen when Gemma returns a non-empty briefing:

1. **Clipboard** — `NSPasteboard.general.setString(briefing, forType: .string)`
2. **Notification** — `UNUserNotificationCenter` posts a local notification:
   - title: `Meeting prep: <event title>`
   - body: first 240 chars of the briefing
   - 1-second `UNTimeIntervalNotificationTrigger` so it appears immediately
3. **Persistence** — the event's `eventIdentifier` is added to
   `processedIds` and saved to disk so the same event is never re-briefed.
   (Force-from-detail-view briefings skip this step so the user can
   repeatedly demo the same event.)

The detail view (`MeetingPrepDetailView`) also keeps the last 3 briefings
in-memory under `state.recentBriefings` so the user can see what was
generated without having to dig through Notification Center.

## Mascot-led detail UI with generation states

`MeetingPrepState.GenerationStatus`:

```swift
enum GenerationStatus: Equatable {
    case idle
    case generating(title: String)
    case success(title: String)
    case error(message: String)
}
```

The detail view's hero card swaps content based on which state Meeting
Prep is in:

- **No calendar access** — "Show me your calendar" + a single "Grant
  calendar access" button.
- **No upcoming events** — calm "Nothing on the books" copy.
- **Upcoming event** — title, start time, attendees, and a "Generate
  briefing now" button.
- **Generating** — animated shimmer over the mascot, "Briefing <title>…"
- **Success / Error** — confirmation or message inline.

The "mascot" is the same logo used in the menubar (`HalenLogo` from
`Resources/HalenLogo.png`), rendered at 56×56 with a coloured shadow to
sell it as a character rather than just an icon.

## Permissions

`MeetingPrep.requestPermissions()` requests two things in sequence:

1. `EKEventStore.requestFullAccessToEvents()` on macOS 14+ (with a
   completion-handler fallback for older systems). Full access is needed
   because in a later milestone the same plugin could **write** prep
   notes back to the event description. Today it only reads.
2. `UNUserNotificationCenter.current().requestAuthorization(options:
   [.alert, .sound])`.

Both authorisation states are surfaced as
`state.calendarAuthorized` / `state.notificationsAuthorized` so the
detail view can show specific "this prompt was denied" guidance.

`Info.plist` usage strings:

- `NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription`:
  > Halen reads your upcoming events to suggest breaks (Burnout Copilot) and
  > prepare briefings before meetings (Meeting Prep). Calendar data is read
  > locally only.

## Storage

File: `~/Library/Application Support/Halen/com.halen.meeting-prep/processed.json`

A plain JSON array of EventKit event identifiers, written atomically.
Identifiers are stable for the life of an event, so this is sufficient
to ensure once-per-event briefing across launches.

## Manual generation

The detail view has a "Generate briefing now" button (`onGenerateNow`).
It picks the next non-all-day event in the next 24 hours and runs the
same `brief(event:force: true)` path with two differences: the
`force` flag means it skips the 13–17 minute gate, and it doesn't write
to `processedIds` (so it can be re-run for demos).
