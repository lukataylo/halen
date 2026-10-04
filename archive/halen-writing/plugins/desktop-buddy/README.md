# Desktop Buddy

A friendly Gemma-powered character that lives on your desktop and helps with
small tasks. Always visible in the bottom-right of your screen. Press **⌃⌥B**
to focus it. Click it to open the input bubble.

## What it does

- **Ask anything.** Type a question into the bubble, get a concise on-device
  answer from Halen's bundled model (Gemma + Qwen).
- **Rewrite the selection.** If text is selected in the focused app when you
  summon the buddy, the bubble switches to a "Rewrite selection" prompt. The
  rewrite is applied in place via the host's accessibility writer.
- **React to your typing tone.** Subscribes to `text.pause`, classifies each
  paragraph (`happy`/`neutral`/`frustrated`), and softly shifts the buddy's
  expression. Switches only after two of three classifications agree, so a
  single sharp sentence won't change the face.
- **Calendar nudges.** Three to ten minutes before each upcoming calendar
  event the buddy pops a speech bubble with the title and time.

## How it's built

```
plugins/desktop-buddy/
├── halen-plugin.json            # manifest the host reads
├── plugin.py                    # JSON-RPC bridge to Halen + NDJSON to companion
├── build.sh                     # builds the Swift companion in release mode
├── bin/                         # symlink to the built binary lives here
└── companion/                   # Swift package — borderless floating window
    ├── Package.swift
    └── Sources/DesktopBuddy/
        ├── main.swift           # NSApp entry
        ├── AppDelegate.swift    # glues bridge → windows
        ├── Bridge.swift         # NDJSON over stdio
        ├── Buddy.swift          # Expression + InputMode types
        ├── BuddyWindow.swift    # floating character window
        ├── BuddyView.swift      # SwiftUI character view
        ├── BubbleWindow.swift   # floating bubble window (say + input)
        └── BubbleView.swift     # SwiftUI bubble contents
```

`plugin.py` runs as a Halen plugin process. It spawns the Swift companion as
a child process and routes messages between the two:

- **Host → plugin.py** over its own stdio: `text.pause` events,
  `hotkey.fired`, inference responses, calendar query responses.
- **plugin.py → companion** over the companion's stdin:
  `{"type":"expression"}`, `{"type":"say"}`, `{"type":"showReply"}`,
  `{"type":"focus"}`, `{"type":"shutdown"}`.
- **Companion → plugin.py** over the companion's stdout:
  `{"type":"clicked"}`, `{"type":"submit"}`, `{"type":"closed"}`,
  `{"type":"ready"}`.

The companion holds no host capabilities of its own — every privileged call
(inference, AX writes, calendar reads, hotkey wiring) goes through
`plugin.py`, then through the host.

## Build

```bash
cd plugins/desktop-buddy
./build.sh
```

Requires Swift 5.10+ and macOS 14. The script runs `swift build -c release`
in `companion/` and symlinks the resulting binary into `bin/DesktopBuddy`.

## Install

Copy the directory into Halen's plugin directory and (re)start Halen:

```bash
mkdir -p ~/Library/Application\ Support/Halen/Plugins
cp -R plugins/desktop-buddy ~/Library/Application\ Support/Halen/Plugins/com.halen.desktop-buddy
```

## Status

Pre-alpha — works end to end but hasn't been polished. The character glyph
is an emoji; a hand-drawn replacement is planned. The companion binary needs
to be code-signed before it can ship through the Plugin Store registry.
