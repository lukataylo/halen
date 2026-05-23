# Inline Autocomplete

> Plugin id: `com.halen.autocomplete` · Category: Writing · Code:
> [`Sources/Halen/Features/Autocomplete/`](../../../Sources/Halen/Features/Autocomplete/)

When the user pauses at the end of what they're typing, Halen asks the
local model for a short continuation and draws it as gray ghost text in
a non-interactive overlay anchored just past the caret. **Tab** accepts
(inserted via AX); any other keystroke dismisses.

## How the overlay works

macOS gives no way to draw real inline ghost text inside an arbitrary
app's text field, so the suggestion floats in a borderless `NSPanel` at
`.floating` level positioned at the caret's on-screen rect.

```
focused field:  "We should probably ship the▮
                                            ^
                                            ┌─────────────────┐
                                            │ release tonight │  ghost panel
                                            └─────────────────┘
```

Alignment is good in native fields (the AX caret rect is accurate) and
rougher in Electron / web fields (cursor bounds can be window-local or
missing entirely). Prototype against **TextEdit / Notes**.

## Trigger conditions

`maybeSuggest` only fires when *all* of these hold:

- The caret sits at the **end of the text** in the focused field
  (mid-paragraph ghosting would overlap real text)
- There are at least **20 characters** of context before the caret
- No other writing plugin has an active finding on this paragraph
  (Sentiment / Clarity / Style — see "Coordination" below)
- A model call isn't already in flight for a stale generation

The inference request is `tier: .small, maxTokens: 12, temperature: 0.3`
— deliberately short, deliberately low-variance. A long, creative
"completion" is a bad fit for ghost text; the user is steering, the
model is just finishing their thought.

## Coordination with other writing plugins

The plugin subscribes to `.findingDetected` / `.findingsCleared` on the
event bus and tracks which plugin sources have an open finding:

```swift
case .findingDetected(let p):
    self.activeFindingSources.insert(p.source)
    self.dismiss()    // tinted indicator owns the surface
case .findingsCleared(let p):
    self.activeFindingSources.remove(p.source)
```

While `activeFindingSources` is non-empty, no ghost text is drawn.
Continuing an irritated/passive sentence with a model suggestion doesn't
make semantic sense either — the user is supposed to be revising, not
extending. This was UX-3 (autocomplete ↔ caret-indicator visual
collision).

## Tab handling

Hijacking Tab globally would be hostile — every other app uses it for
focus traversal. So the hotkey is registered *only while a suggestion is
on screen*, and immediately unregistered on:

- Accept (Tab pressed → AX-insert → dismiss → unregister)
- Dismiss (any other keystroke / caret moved / app focused → unregister)
- Auto-dismiss (suggestion left untouched for the timeout → unregister)

The "generation" counter inside the plugin guards against late model
responses landing on top of a newer suggestion request.

## Why this plugin is OFF by default

A continuous suggestion stream is great for some people and an active
annoyance for others. Onboarding flips it on for the curious; everyone
else gets quiet typing.

## What it does NOT do

- **Latency control.** No "wait 200ms vs 500ms before suggesting" slider
  yet — the settle delay is the `ParagraphClassifier` default. Queued.
- **App whitelist.** No "only suggest in Notes and TextEdit" option;
  it's all or nothing. Queued.
- **Multi-word visible diff.** The accept inserts the whole suggestion;
  there's no "Tab once for the next word, Tab again for the next phrase"
  yet.
