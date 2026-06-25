# Prompt Polish

> Plugin id: `com.halen.prompt-polish` · Category: Productivity · Code:
> [`Sources/Halen/Features/PromptPolish/`](../../../Sources/Halen/Features/PromptPolish/)

Select the prompt you're about to send to an AI — in any app, including a
ChatGPT, Claude, or Gemini text box — and press **⌃⌥⌘P**. Halen rewrites it in
place with targeted **word-level edits** so a modern model answers it well. A
`[…]` placeholder shows while the on-device model works; ⌘Z undoes.

This is the applied side of the [`register-lab`](../../../research/register-lab/)
study: word choice steers a model's output, so the most effective way to improve
a prompt is to fix the *words* — not rewrite it wholesale.

## The four modes

⌃⌥⌘P applies whichever mode is selected in the detail view. They map to the most
common prompting tasks:

| Mode | What it changes |
|---|---|
| **Improve** | Vague words → precise; weak verbs → strong; adds format/length/audience when implied; cuts filler. |
| **Set tone** | Swaps register-marking words + adds one tone instruction to steer the answer's voice (Professional / Casual / Academic / Concise). |
| **Summarise** | Pins a concrete length and format (3 bullets, one sentence, <100 words) and a precise verb. |
| **Coding** | Names language/version, states desired output and constraints, turns "fix this" into a precise ask. |

The instruction for each mode tells the model to treat the selection as *the
prompt to edit*, never to answer it, and to "output only the rewritten prompt".

## Why on-device, not Gemini

The mode instructions are *calibrated to* how modern instruction-tuned models
(Gemini-, GPT-, Claude-class) behave — role framing, explicit format/audience,
register-marking word choice — all corroborated by first-party prompt-
engineering docs (see [`RELATED_WORK.md`](../../../research/register-lab/RELATED_WORK.md)).
But the rewrite itself runs on Halen's existing local models via the inference
router (`tier: .medium`), so the prompt never leaves the Mac. No cloud backend,
no API key, consistent with Halen's privacy promise.

## How the write-back works

Hotkey-only — the plugin does not subscribe to text events, so it needs no
self-edit suppression. On ⌃⌥⌘P it reads the selection via AX, drops a `[…]`
placeholder, streams the model's output into it (re-locating the placeholder on
each snapshot in case the user edits the field mid-call), then writes the
cleaned final text — or restores the original on an empty/failed response. The
choreography mirrors Snippet Expander's proven ⌃⌥R rephrase path.

## What it does NOT do

- **No preview/diff.** It rewrites in place; you compare against your memory of
  the original (or ⌘Z). A side-by-side review panel is queued.
- **No per-mode hotkeys.** One chord (⌃⌥⌘P) applies the configured default mode;
  switching mode is a click in the detail view.
- **No app whitelist.** ⌃⌥⌘P is global, like ⌃⌥R / ⌃⌥E.
