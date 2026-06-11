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
token savings; press ⌘V to paste it back.

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
  by **~40% (313 → 181 on GSM8K) with < 0.4% accuracy drop**. — *TokenSkip:
  Controllable Chain-of-Thought Compression in LLMs*, EMNLP 2025,
  arXiv:2502.12067.

This plugin applies the same principle at the prompt level rather than by
fine-tuning: it instructs the local model to keep every load-bearing step
(facts, equations, intermediate results, the conclusion verbatim) and drop the
connective filler, targeting roughly **45% of the original token count** — in
line with TokenSkip's reported reduction. The target adapts to how much
redundancy the model actually finds; if a trace is already tight, the plugin
detects that the output didn't shrink and tells you so instead of "compacting"
it into something worse.

### References

- *Making Slow Thinking Faster: Compressing LLM Chain-of-Thought via Step
  Entropy* — https://arxiv.org/abs/2508.03346
- *TokenSkip: Controllable Chain-of-Thought Compression in LLMs* (EMNLP 2025) —
  https://arxiv.org/abs/2502.12067 · code: https://github.com/hemingkx/TokenSkip
- *TokenSqueeze: Performance-Preserving Compression for Reasoning LLMs* —
  https://arxiv.org/abs/2511.13223

## Install

Copy this directory into Halen's plugins folder and restart Halen:

```bash
cp -R reasoning-compactor \
  ~/Library/Application\ Support/Halen/Plugins/com.halen.reasoning-compactor
```

Then enable **Reasoning Compactor** in Halen's plugin list.

## Protocol surface

| Direction | Method / event | Why |
|---|---|---|
| plugin → host | `hotkey/register` | binds ⌃⌥K (keyCode 40, modifiers `0x1800`) |
| host → plugin | `event/hotkey.fired` | the user pressed ⌃⌥K |
| host → plugin | `event/text.pause` | background detection of bloated traces |
| plugin → host | `ax/readSelection` | read the selected reasoning |
| plugin → host | `inference/complete` | on-device compaction (`tier: medium`) |
| plugin → host | `ui/toast` | report savings / nudge |

The clipboard write uses `/usr/bin/pbcopy`, a subprocess the plugin spawns
itself — no host capability is involved. Declared permissions: `inference`,
`ax.read`, `notifications`.

## Tuning

The constants near the top of `plugin.py` are the knobs:

- `TARGET_KEEP_RATIO` — fraction of tokens to aim to keep (default `0.45`).
- `MIN_CHARS` — minimum selection length before ⌃⌥K does anything.
- `NUDGE_MIN_CHARS` / `NUDGE_MIN_SAVED_TOKENS` / `NUDGE_COOLDOWN` — how eager the
  background nudge is.
