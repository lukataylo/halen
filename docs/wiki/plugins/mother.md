# Mother

> Plugin id: `com.halen.mother` · Category: Focus · Code:
> [`plugins/mother/`](../../../plugins/mother/)
>
> **Runs out-of-process** as a JSON-RPC plugin over stdio, like Meeting
> Prep and Burnout Copilot. The menubar app brokers `app.focused` events
> to it and proxies the notifications and modal prompts it asks for
> (`ui/toast`, `ui/prompt`). Quitting an app and closing a browser tab is
> done by Mother's own `osascript` subprocess — the same mechanism
> Burnout Copilot uses to fire a Shortcut. Mother holds no macOS
> entitlements of her own. See
> [plugins/README.md](../../../plugins/README.md) for the protocol.

Mother is a discipline enforcer. You give her a blocklist of apps and
websites; she keeps you off them. Everything is local — no network, no
accounts, no telemetry. She is deliberately not gentle: during your focus
hours she quits the app or closes the tab without asking.

## What she watches

| Surface | Source | How |
|---|---|---|
| **Apps** | `app.focused` events from the host | When a blocklisted app takes focus, a short grace timer starts. If the app is *still* frontmost when it elapses, Mother acts. |
| **Sites** | The front browser tab | While a known browser is frontmost, a poller reads the active tab's URL over AppleScript every few seconds and matches it against the site blocklist. |

The grace timer re-checks the frontmost app **live** (via System Events)
rather than trusting the focus event — ⌘-Tabbing past a blocked app
within the grace window is forgiven, not punished.

Supported browsers for site enforcement: Safari (+ Technology Preview),
Chrome (+ Canary), Brave, Edge, Vivaldi, and Arc. Firefox has no reliable
AppleScript tab API, so its tabs aren't read.

## The three strictness levels

Set `enforcement` in `config.json`:

| Level | Inside focus hours | Outside focus hours |
|---|---|---|
| `soft` | Stern notification, logged. Nothing is closed. | Same. |
| `hardcore` *(default)* | Quits the app / closes the tab immediately. **No override.** | Confronts you first; you can buy a short, logged override — behind a two-step confirm. |
| `lockdown` | Immediate, always. No prompt, no override, ever. | Immediate, always. |

Apps are quit gracefully (`tell application … to quit`), so an app with
unsaved work can still prompt you to save. Sites are closed tab-first and
explained after, since a closed tab is cheaper to undo than a quit app.

An override never re-opens anything. It just stops Mother re-nuking the
same app or host for `overrideMinutes` (default 5) so you can return to it
on purpose. Every override is written to the ledger.

## Configuration

`~/Library/Application Support/Halen/com.halen.mother/config.json` is
seeded with sane defaults on first run and **hot-reloaded** whenever the
file's mtime changes (checked every 5 s) — no restart needed.

```jsonc
{
  "enforcement": "hardcore",        // soft | hardcore | lockdown
  "graceSeconds": 6,                // blocked app may hold focus this long first
  "sitePollSeconds": 3,             // front-tab read cadence while a browser is up
  "confrontTimeoutSeconds": 45,     // silence on the confront modal == "I'm staying"
  "overrideMinutes": 5,             // how long an override pass lasts
  "focusHours": [                   // days: 0=Mon … 6=Sun; times local 24h
    { "days": [0,1,2,3,4], "start": "09:00", "end": "18:00" }
  ],
  "blockedApps": [
    { "bundleId": "com.hnc.Discord", "name": "Discord" }
    // …
  ],
  "blockedSites": ["x.com", "twitter.com", "reddit.com", "youtube.com"]
}
```

A `focusHours` window whose `end` is `<=` its `start` is treated as
spanning midnight (e.g. `"22:00"`–`"06:00"`).

### Site matching

A `blockedSites` rule matches the tab's host and any subdomain of it:
`reddit.com` blocks `www.reddit.com` and `old.reddit.com`, but **not**
`notreddit.com.evil.com` — matching is on host boundaries, not substrings.

## The ledger

`~/Library/Application Support/Halen/com.halen.mother/state.json` is
Mother's local record. Every action — `warned`, `quit`, `closed-tab`,
`override` — is appended with a timestamp, the target, and the kind
(`app`/`site`). The last 500 entries are kept, plus running totals. It is
plain JSON; nothing leaves your Mac.

## Why osascript and not a host capability

Reading a browser tab's URL and closing it, and quitting an app, are
ordinary macOS automation. Rather than add new privileged host methods,
Mother shells out to `osascript` from her own process — exactly as
Burnout Copilot does to run a Shortcut. The first time she reads a tab or
closes one, macOS shows its standard Automation (Apple Events) consent
prompt for *that* browser; the grant is between Mother's subprocess and
the browser, managed by the OS. The host's only jobs are the toast and
the modal prompt.
