# Halen — 1-minute demo

A beat-by-beat script. Practice once with a stopwatch; everything below is timed
so the demo runs in **60 seconds flat** with no dead air.

> Setup before you start: open **TextEdit** with a blank document; open
> **System Settings → Privacy & Security → Accessibility** in a tab beside it
> in case you need to show the permission was granted; have **Halen** running
> with all five plugins enabled (the dropdown shows "5 of 5 plugins active").

---

## 0:00 — 0:08 · Open the marketplace

> *"Halen is a local-first writing agent for macOS. Every feature ships as a
> plugin. Here's the marketplace."*

- Click the **Halen icon** in the menubar.
- Hover over each plugin card briefly: *Ask Halen, Writing Assistant,
  Snippet Expander, Voice Dictation, Prompt Polish.*
- *"five bundled plugins. All running locally. No cloud calls anywhere."*

## 0:08 — 0:23 · Typo correction (15 s)

> *"It already knows my frequent typos."*

- Click into TextEdit. Type:
  ```
  i need to udnerstand the application better
  ```
  …pausing briefly after **`udnerstand `** (with trailing space).
- **Halen auto-fixes** `udnerstand → understand`, then `applciation → application`
  (if you type that one).
- *"That came from a personal seeded dictionary — 32 entries. But it also
  learns. If I correct something twice, it auto-fixes from then on. And if
  it gets it wrong, I backspace + retype the original and it demotes the
  entry forever."*

## 0:23 — 0:40 · Sentiment Guard (17 s)

> *"Now watch what happens if I write something I might regret."*

- Click into a fresh paragraph. Type (you can prep this in muscle memory):
  ```
  This is absolutely unacceptable. I'm furious about how you handled this and I expect better immediately.
  ```
- **Pause for ~1 second** after the period. A **cobalt popover** anchors near
  the cursor: *"This reads as **hostile**"* with **Looks fine** and
  **Rephrase via Gemma 4** buttons.
- *"That's Gemma 4 E4B classifying the tone locally. I can wave it through —
  it remembers the fingerprint so it never re-flags this exact text. Or I can
  let Gemma rewrite it."*
- Click **Rephrase via Gemma 4**. Wait ~2 s. Quietly **⌘V** into a fresh line
  to paste the calmer version.
- *(Optional, if time:)* Open the marketplace → tap **Sentiment Guard** →
  point at the **5 built-in rules + add your own** UI. *"Hostile, irritated,
  passive-aggressive, anxious, overly corporate — toggle any of them, or
  write your own Gemma prompt."*

## 0:40 — 0:52 · Text expansion (12 s)

> *"It also expands snippets — including ones backed by Gemma."*

- In TextEdit, type a paragraph (~3-4 sentences) about anything — Q4 priorities,
  a product idea, whatever. Then type:
  ```
  ;formal
  ```
  followed by **space**.
- Halen shows `[…]` briefly while Gemma rewrites, then swaps in a formal
  version of the paragraph above the trigger.
- *(Optional, if time:)* type `;today ` → see today's date drop in.
- *"All on-device. The 500 chars above my cursor go to my local Gemma. The
  output replaces the trigger. I can add my own snippets — static text or
  custom Gemma prompts."*

## 0:52 — 1:00 · Tone per app + wrap (8 s)

> *"And it knows the tone each app expects."*

- Open the menubar → **Writing Assistant → Tone**. Show the **per-app target
  tone** list: *"Outlook → Formal, Teams → Business casual."*
- *"Write something too casual in a formal app and Halen flags it — with a
  one-tap rewrite to the right register. All on-device."*
- Close the dropdown.
- *"That's Halen. bundled plugins, local Gemma 4, every keystroke private.
  Built in a hackathon."* 🎤

---

## Cheat sheet — phrases that need to land

- **Local-first.** Everything runs on the user's Mac. No cloud.
- **Plugin architecture.** Each feature is a HalenPlugin module; users can
  enable/disable independently.
- **Gemma 4.** The on-device frontier model released April 2026; E4B is the
  default tier; E2B handles fast classification paths.
- **five bundled plugins out of the box.** Designed so judges can see breadth quickly.
- **Built in a hackathon.** Don't apologise — every line is recent.

## Things to avoid

- Don't open Slack / Mail — they're Electron and AX write-back is unreliable.
  Stick to **TextEdit / Notes / Mail compose / Pages**.
- Don't dwell on the Halen icon size or any UI thing that didn't ship pixel-
  perfect — the demo is about what it does, not how it looks.
- Don't say "we built this" — single-developer hackathon framing reads
  stronger.
