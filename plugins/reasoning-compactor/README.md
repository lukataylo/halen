# Reasoning Compactor

A developer plugin that **compacts verbose LLM reasoning on-device**. Reasoning
models ("thinking" models) spend a lot of tokens talking to themselves — false
starts, restatements, "let me think", "wait, actually…". Reasoning Compactor
keeps the load-bearing steps and the final answer and throws away the filler,
using Halen's *local* model so nothing leaves your machine.

It is provider-agnostic by design: it operates on the reasoning text in front
of you, not on any vendor's API, so it works with chain-of-thought from
**Claude, GPT, Gemini, DeepSeek-R1, local Qwen/Llama**, or anything else.

## What it does

**⌃⌥K — compact the selection.** Select a reasoning trace anywhere — a browser
chat, a terminal, your editor, a scratch file — and press ⌃⌥K. The plugin reads
the selection through the host's accessibility bridge, runs the compaction pass
on-device, and puts the result on the clipboard. A notification reports the
token savings — e.g. `~1.9k → 620 tokens · 3.1× smaller (−68%). ⌘V to paste.` —
and a running per-session total (with an estimated dollar saving).

> Why the clipboard instead of rewriting in place? Reasoning traces live in
> browser chats, terminals and Electron editors, exactly the surfaces where
> direct accessibility writes are unreliable — Halen's own AX layer falls back
> to a clipboard paste there. Copy-and-paste is the one mechanism that behaves
> identically everywhere, and it's non-destructive: nothing is overwritten
> until *you* paste.

**Background nudge.** While enabled the plugin watches focused text fields
(`text.pause`). When a long, redundant reasoning trace settles in a field it
posts a single notification telling you roughly how many tokens you'd save by
compacting it (with an 8-minute per-field cooldown so it never nags). It never
rewrites anything on its own — it only points at the opportunity.

On shutdown it logs how many traces it compacted and the approximate total
tokens saved for the session.

## How the compaction works

The prompt follows the 2025 chain-of-thought-compression literature. The core
idea, established by Alibaba's step-entropy work and by TokenSkip, is that a
large fraction of reasoning tokens are *low-information* — removing them barely
moves answer accuracy:

- **Step-entropy CoT compression** (Alibaba Group / Tongyi Lab) measures the
  information each reasoning step carries and prunes the low-entropy ones,
  removing **~80% of steps while retaining ~90%+ of accuracy** on math
  benchmarks. — *Making Slow Thinking Faster: Compressing LLM Chain-of-Thought
  via Step Entropy*, arXiv:2508.03346.
- **TokenSkip** makes the compression ratio *controllable* by letting the model
  skip less-important tokens. On Qwen2.5-14B-Instruct it cuts reasoning tokens
  by **~40% (313 → 181 on GSM8K) with < 0.4% accuracy drop**, and notes that
  *"mathematical equations tend to have a greater contribution to the final
  answer"* while *"semantic connectors such as 'so' and 'since' generally
  contribute less."* — *TokenSkip: Controllable Chain-of-Thought Compression in
  LLMs*, EMNLP 2025, arXiv:2502.12067.

This plugin applies the same principle at the prompt level rather than by
fine-tuning: it instructs the local model to keep every load-bearing step
(facts, equations, intermediate results, the conclusion verbatim) and drop the
connective filler, targeting roughly **45% of the original token count** — in
line with TokenSkip's reported reduction.

## Design borrowed from comparable projects

These behaviours were lifted from the established prompt/CoT-compression tools
after reviewing them:

| Learning | Source | How it shows up here |
|---|---|---|
| Two compression modes: a **rate** *and* an absolute **target-token budget** | LLMLingua (`rate` vs `target_token`) | `target_keep_ratio` and `target_tokens` in `config.json` — set `target_tokens > 0` for a hard budget |
| **Protect content that must survive** compression | LLMLingua `force_tokens` / `compress=False`; TokenSkip "keep the answer unchanged" | Fenced code blocks are split out and passed through **verbatim, never sent to the model**; the prompt pins the final answer, equations, numbers and identifiers |
| **Report real savings**, not just a ratio | LLMLingua returns `origin_tokens`, `compressed_tokens`, `ratio`, `$ saving` | Toast shows `N → M tokens · X× smaller (−P%)` plus a session token + dollar total |
| **Chunk long inputs** so output isn't truncated | LLMLingua coarse-to-fine / budget controller | Inputs over `max_single_pass_tokens` are compacted paragraph-chunk by chunk and reassembled in order |

### References

- *Making Slow Thinking Faster: Compressing LLM Chain-of-Thought via Step
  Entropy* — https://arxiv.org/abs/2508.03346
- *TokenSkip: Controllable Chain-of-Thought Compression in LLMs* (EMNLP 2025) —
  https://arxiv.org/abs/2502.12067 · code: https://github.com/hemingkx/TokenSkip
- *LLMLingua / LLMLingua-2* (Microsoft) — https://github.com/microsoft/LLMLingua
- *TokenSqueeze: Performance-Preserving Compression for Reasoning LLMs* —
  https://arxiv.org/abs/2511.13223

## Install

Copy this directory into Halen's plugins folder and restart Halen:

```bash
cp -R reasoning-compactor \
  ~/Library/Application\ Support/Halen/Plugins/com.halen.reasoning-compactor
```

Then enable **Reasoning Compactor** in Halen's plugin list.

## Configuration

Edit `config.json` next to `plugin.py` (re-enable the plugin or restart Halen to
reload). Every key is optional and falls back to the default below.

| Key | Default | Meaning |
|---|---|---|
| `target_keep_ratio` | `0.45` | Fraction of tokens to aim to keep (clamped to 0.1–0.95). |
| `target_tokens` | `0` | Absolute output budget. `> 0` overrides the ratio. |
| `usd_per_million_tokens` | `3.0` | Price used for the dollar-saved estimate in toasts. |
| `min_chars` | `480` | Minimum selection length before ⌃⌥K does anything. |
| `nudge_min_chars` | `900` | Minimum field length before the background nudge considers it. |
| `nudge_min_saved_tokens` | `80` | Don't nudge unless at least this many tokens are saveable. |
| `nudge_cooldown_seconds` | `480` | Per-trace cooldown between nudges. |
| `max_single_pass_tokens` | `1200` | Prose above this is chunked so the model's output can't be truncated. |
| `clipboard_cmd` | `["/usr/bin/pbcopy"]` | Command that receives the compacted text on stdin. |
| `hotkey_keycode` / `hotkey_modifiers` | `40` / `6144` | Carbon key code + modifier bitmask (default ⌃⌥K). |

`HALEN_RC_CLIPBOARD_CMD`, `HALEN_RC_TARGET_RATIO` and `HALEN_RC_TARGET_TOKENS`
environment variables override the corresponding keys (used by the test
harness).

## Protocol surface

| Direction | Method / event | Why |
|---|---|---|
| plugin → host | `hotkey/register` | binds ⌃⌥K (keyCode 40, modifiers `0x1800`) |
| host → plugin | `event/hotkey.fired` | the user pressed ⌃⌥K |
| host → plugin | `event/text.pause` | background detection of bloated traces |
| plugin → host | `ax/readSelection` | read the selected reasoning |
| plugin → host | `inference/complete` | on-device compaction (`tier: medium`) |
| plugin → host | `ui/toast` | report savings / nudge |

The clipboard write uses the configured `clipboard_cmd` (`/usr/bin/pbcopy` by
default), a subprocess the plugin spawns itself — no host capability is
involved. Declared permissions: `inference`, `ax.read`, `notifications`.

## Verification

The logic is covered by a unit suite (token estimation, reasoning detection,
code-aware segmentation incl. unclosed fences, paragraph chunking, ratio vs
absolute-budget targeting, config/env overrides) and an end-to-end harness that
runs `plugin.py` as a subprocess and plays the host over JSON-RPC stdio:
handshake, hotkey registration, the segmentation + code-preservation path (and
that **code is never sent to the model**), the short-selection guard, chunking
of a long trace into multiple passes, the background nudge plus cooldown
suppression, and clean shutdown.
