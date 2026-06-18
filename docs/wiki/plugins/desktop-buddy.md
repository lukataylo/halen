# Desktop Buddy

> Plugin id: `com.halen.desktop-buddy` · Category: Productivity · Code:
> [`plugins/desktop-buddy/`](../../../plugins/desktop-buddy/)
>
> **Pre-alpha — deliberately NOT in the Plugin Store.** It ships a Swift
> companion app (the floating character window) that has to be built locally
> and code-signed before it can be distributed, so it isn't listed in the
> store registry yet. Build the companion with `build.sh` (below) and install
> it by hand to try it.
>
> **Runs out-of-process** as a JSON-RPC plugin over stdio, like Meeting Prep
> and Burnout Copilot. `plugin.py` is a bridge: JSON-RPC to the Halen host on
> one side, NDJSON over a child pipe to the Swift companion on the other. The
> companion holds no host capabilities of its own — every privileged call
> (inference, AX reads/writes, calendar reads, hotkey wiring) goes through
> `plugin.py`, then through the host. Declared permissions: `calendar`,
> `inference`, `ax.write`, `ax.read`. See
> [plugins/README.md](../../../plugins/README.md) for the protocol.

Desktop Buddy is a friendly Gemma-powered character that lives in the
bottom-right of your screen. Press **⌃⌥B** to focus it; click it to open the
input bubble. Everything runs on-device through Halen's bundled model.

## What it does

| Surface | Trigger | What happens |
|---|---|---|
| **Ask anything** | ⌃⌥B, then type | Type a question into the bubble and get a concise on-device answer (`tier: medium`, under 120 words, plain prose). |
| **Rewrite the selection** | ⌃⌥B with text selected | If the focused app has a non-empty selection when you summon the buddy, the bubble switches to a "Rewrite selection" prompt. The rewrite is applied in place via the host's accessibility writer (`ax/replaceRange`); if the write fails it shows you the rewrite to copy. |
| **React to your typing tone** | `text.pause` | Classifies each settled paragraph (`happy` / `neutral` / `frustrated`, `tier: small`) and softly shifts the buddy's expression. It only switches the face after two of the last three classifications agree, so a single sharp sentence won't change it. |
| **Calendar nudges** | every ~4 min | Between 3 and 10 minutes before an upcoming event, the buddy pops a speech bubble with the title and time. Each event is nudged once. |

## How it's built

```
plugins/desktop-buddy/
├── halen-plugin.json   # manifest the host reads
├── plugin.py           # JSON-RPC bridge to Halen + NDJSON to the companion
├── build.sh            # builds the Swift companion in release mode
├── bin/                # symlink to the built binary lives here
└── companion/          # Swift package — borderless floating window + bubble
```

`plugin.py` spawns the Swift companion as a child process and routes messages
between the two: host events (`text.pause`, `hotkey.fired`, inference and
calendar responses) come in over its own stdio, while companion events
(`clicked`, `submit`, `closed`, `ready`) arrive over the companion's stdout. It
drives the companion with one-line JSON messages (`expression`, `say`,
`showReply`, `focus`, `shutdown`).

## Build

```bash
cd plugins/desktop-buddy
./build.sh
```

Requires Swift 5.10+ and macOS 14. The script runs `swift build -c release` in
`companion/` and symlinks the resulting binary into `bin/DesktopBuddy`. If the
companion binary can't be found at startup, `plugin.py` logs where it looked
and the buddy never appears — build it first.

## Install

```bash
mkdir -p ~/Library/Application\ Support/Halen/Plugins
cp -R plugins/desktop-buddy \
  ~/Library/Application\ Support/Halen/Plugins/com.halen.desktop-buddy
```

Then (re)start Halen and enable **Desktop Buddy** in the plugin list.

## Status

Pre-alpha — works end to end but hasn't been polished. The character glyph is
an emoji; a hand-drawn replacement is planned. The companion binary needs to be
code-signed before it can ship through the Plugin Store registry, which is why
it's distributed only as source for now.
