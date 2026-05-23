# Tone Profiles

> Plugin id: `com.halen.tone-profiles` · Category: Writing · Code:
> [`Sources/Halen/Features/ToneProfiles/`](../../../Sources/Halen/Features/ToneProfiles/)

A small editor on top of a host-owned service. Lets the user tell Halen
which apps they write *formally* in (Mail, the company wiki) and which
they don't (Slack, iMessage). Every other writing plugin reads this
hint to calibrate their suggestions — a blunt Slack message isn't
judged the way a blunt email is.

## The data

```swift
enum ToneProfile: String { case formal, casual, neutral }
```

`AppToneProfileStore` is a `HalenServices.toneProfiles` host service —
keyed by app bundle id, defaulting to `.neutral` when unset. Persisted at
`~/Library/Application Support/Halen/com.halen.tone-profiles/profiles.json`.

## The integration point

Sentiment Guard and Clarity Checker drop a `toneProfile.promptClause`
into their classifier prompts:

```swift
let toneClause = services.toneProfiles.profile(for: appBundleId).promptClause
let prompt = """
You are a tone classifier. …
\(toneClause)
…
"""
```

Where `promptClause` reads:

| Profile | Clause appended to the classifier prompt |
|---|---|
| `formal` | "The user writes in a formal, professional register in this app; hold the text to a polished, measured standard." |
| `casual` | "The user writes in a casual, relaxed register in this app; brief or blunt phrasing is normal and should not be over-flagged." |
| `neutral` | "The user writes in a neutral register in this app." |

That single sentence is enough to materially shift Qwen 0.5B's judgement
on the same message text — "ok" reads as terse-but-fine in a Slack DM,
and curt-bordering-on-rude in an email.

## The editor

The plugin's detail view is the assignment UI. It draws from
`RecentAppsModel` — an in-memory tally of apps focused this session, fed
by `.appFocused` events on the event bus — so the user picks from a list
of apps they actually use rather than typing bundle ids by hand.

Each row shows the app's display name + bundle id + a three-way segmented
control (Formal / Casual / Neutral). Changes write through to the store
synchronously; the next classification picks them up.

## Why the plugin is OFF by default

A casual-by-default vs. formal-by-default decision is consequential, and
most users would never visit the editor. Better to ship neutral
everywhere, surface the plugin during onboarding, and let curious users
opt in than to misread the user's preferred register in their inbox out
of the gate.

## What it does NOT do

- **Per-thread overrides.** Slack-the-app is one bucket; Slack-with-your-CEO
  and Slack-with-your-friends are not separable yet.
- **Auto-detection.** No "Halen noticed you write formally here; switch
  the profile?" prompt. The user is the source of truth.
- **Bulk assignment.** Each app is set individually. Tagging multiple
  apps in one gesture is queued as a follow-up.
