# Halen local compaction (Claude Code plugin)

A Claude Code plugin that compacts your context **on-device with Halen's local
model** — your conversation is never sent to the cloud for the summary step.
It's the Claude Code half of Halen's **Reasoning Compactor**: enable Reasoning
Compactor in Halen and this plugin is installed and wired up for you.

## What it does

When Claude Code is about to compact your context — you ran `/compact`, or the
window filled up and it auto-compacted — this plugin's **PreCompact** hook
reads the transcript, asks the running Halen app's local model to compact it,
and saves the result. When you later **resume** that session (`--resume`,
`--continue`, or the fresh context Claude Code opens right after a compaction),
the **SessionStart** hook injects that local summary back as context.

So the summary that carries your session forward is produced by Halen's
on-device model, not a cloud round-trip.

> **What it does not do:** it does not replace Claude Code's own built-in
> compaction (a hook can't), and it doesn't stop the cloud model from running
> if you let auto-compaction fire. It runs a *parallel, local* compaction and
> restores that local summary on resume. Set `frequency` to `manual` and run
> `/compact` yourself if you want the local pass to be the only one that
> matters.

## How it reaches the local model

The hook talks to the **running Halen app** over its local WebSocket bridge
(`127.0.0.1:50765`), authenticating with the bridge token Halen writes to
`~/Library/Application Support/Halen/bridge-token`. It calls
`inference/complete`, the same on-device inference surface Halen's own plugins
use. No cloud, no API key, no extra model download — it reuses the model Halen
already runs.

If Halen isn't running (or the bridge is off), the hook exits cleanly and does
nothing — it never blocks or breaks Claude Code's own `/compact`.

## Compaction strategy

Same approach as Halen's Reasoning Compactor and the 2025 CoT-compression
literature (TokenSkip, step-entropy, LLMLingua):

- **`extractive` (default)** — the local model picks which conversation *turns*
  to keep; the summary is rebuilt **verbatim** from your real turns, and the
  latest turn is always kept. It can't invent content that wasn't there. If the
  model's selection can't be parsed, it falls back to an abstractive pass so you
  still get a summary.
- **`abstractive`** — the model rewrites the conversation into a tight briefing.
  Smaller, but faithfulness depends on the model.

## Configure

Run **`/halen-local-compaction:configure`** in Claude Code, or edit
`config.json` in this plugin's directory. Keys:

| Key | Default | Meaning |
|---|---|---|
| `frequency` | `"auto"` | `auto` runs on manual + automatic compaction; `manual` only on `/compact`. |
| `min_tokens` | `6000` | Skip compaction for transcripts smaller than this. |
| `type` | `"extractive"` | `extractive` (verbatim subset) or `abstractive` (rewrite). |
| `target_keep_ratio` | `0.4` | Fraction of tokens to aim to keep (0.1–0.95). |
| `target_tokens` | `0` | Hard output budget; `> 0` overrides the ratio. |
| `preserve` | `["code","decisions","final_answers"]` | What to always keep. |
| `inject_on_resume` | `true` | Re-inject the saved local summary on resume. |
| `model_tier` | `"medium"` | Which local Halen model runs it (`small`/`medium`/`large`). |
| `bridge_port` | `50765` | Halen's local bridge port. |
| `max_prompt_chars` | `160000` | Transcript is clipped to its tail below this so the request fits the bridge frame cap. |

## Install

Normally you don't install this by hand — enabling **Reasoning Compactor** in
Halen installs it into a local Claude Code marketplace and enables it in
`~/.claude/settings.json`. To install manually for development:

```bash
claude --plugin-dir /path/to/this/claude-code
```

or register the parent marketplace and `enabledPlugins` entry as Halen does
(see `extraKnownMarketplaces` / `enabledPlugins` in your `~/.claude/settings.json`).

## Verification

Pure logic and the WebSocket frame codec are covered by `test_compaction.py`
(stdlib `unittest`, no Halen/network/model):

```bash
python3 test_compaction.py
```

It exercises config coercion/clamping, the frequency gate, transcript parsing
(string + block content, malformed lines), tail-clipping on turn boundaries,
extractive/abstractive prompt building, the keep-index parser (standalone-int
only, out-of-range filtering, force-kept last turn, parse-failure → `None`),
savings reporting, and the RFC-6455 frame codec (masked client frames, unmasked
server frames, 16-bit lengths, partial-buffer carry-over, multiple frames per
buffer, ping/close opcodes). The model-dependent quality is validated manually
against a real local model, exactly as Reasoning Compactor is.
