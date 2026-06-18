# Reasoning Compactor

> Plugin id: `com.halen.reasoning-compactor` · Category: Productivity · Code:
> [`plugins/reasoning-compactor/`](../../../plugins/reasoning-compactor/)
>
> **Runs out-of-process** as a JSON-RPC plugin over stdio, like Meeting Prep
> and Burnout Copilot. The menubar app brokers `text.pause` events and the
> ⌃⌥K hotkey to it, and proxies the calls it makes back — `ax/readSelection`
> to read the selected reasoning, `inference/complete` to run the on-device
> compaction (`tier: medium`), and `ui/toast` to report savings. Writing the
> result to the clipboard is done by the plugin's own `/usr/bin/pbcopy`
> subprocess — the same pattern Burnout Copilot uses to fire a Shortcut — so
> the plugin holds no macOS entitlements of its own. Declared permissions:
> `inference`, `ax.read`, `notifications`. See
> [plugins/README.md](../../../plugins/README.md) for the protocol.

Reasoning models spend a lot of tokens talking to themselves — false starts,
restatements, "let me think", "wait, actually…". Reasoning Compactor keeps the
load-bearing steps and the final answer and throws away the filler, using
Halen's *local* model so nothing leaves your machine. It is provider-agnostic
by design: it operates on whatever reasoning text is in front of you, not on
any vendor's API, so it works with chain-of-thought from Claude, GPT, Gemini,
DeepSeek-R1, local Qwen/Llama, or anything else.

## Two ways in

| Surface | Trigger | What happens |
|---|---|---|
| **Compact the selection** | ⌃⌥K | Select a reasoning trace anywhere — a browser chat, a terminal, your editor — and press ⌃⌥K. The plugin reads the selection over the host's accessibility bridge, runs the compaction pass on-device, and puts the result on the **clipboard**. A toast reports the savings, e.g. `~1.9k → 620 tokens · 3.1× smaller (−68%). Press ⌘V to paste.`, plus a running per-session token (and estimated dollar) total. |
| **Background nudge** | `text.pause` | While enabled it watches focused text fields. When a long, redundant trace settles in one, it posts a single notification estimating how many tokens you'd save by compacting it — with an 8-minute per-field cooldown so it never nags. It never rewrites anything on its own. |

Why the clipboard instead of rewriting in place? Reasoning traces live in
browser chats, terminals and Electron editors — exactly the surfaces where
direct accessibility writes are unreliable, and where Halen's own AX layer
falls back to a clipboard paste. Copy-and-paste behaves identically everywhere
and is non-destructive: nothing is overwritten until *you* paste.

## Extractive vs abstractive

The compaction strategy follows the 2025 chain-of-thought-compression
literature (Alibaba's step-entropy work; TokenSkip, EMNLP 2025; Microsoft's
LLMLingua), which all compress *extractively* — keeping or dropping original
units rather than rewriting, because rewriting risks paraphrasing or
hallucinating the logic. The plugin defaults to the same mechanism:

| Mode | How |
|---|---|
| `extractive` *(default)* | The trace is split into numbered steps; the local model is asked only *which steps to keep*; the output is rebuilt from those original steps **verbatim**. Faithful by construction — the model can't invent reasoning that wasn't there — and the **final answer is force-kept** even if the model omits it. |
| `abstractive` | The model rewrites the trace shorter. Tighter output, but faithfulness depends on the model honouring the prompt. Set `"mode": "abstractive"` in `config.json` to opt in. |

If extractive selection can't be parsed from the model's reply, the plugin
falls back to an abstractive pass so you still get compaction.

Fenced code blocks are split out and passed through **verbatim — never sent to
the model** — since code carries the reasoning. Inputs above
`max_single_pass_tokens` are chunked paragraph-by-paragraph and reassembled in
order so the model's output can't be truncated.

## Configuration

Edit `config.json` next to `plugin.py` (re-enable the plugin or restart Halen
to reload). Every key is optional and falls back to the default below.

```jsonc
{
  "mode": "extractive",            // extractive (faithful subset) | abstractive (rewrite)
  "target_keep_ratio": 0.45,       // fraction of tokens to keep (clamped 0.1–0.95)
  "target_tokens": 0,              // >0 ⇒ absolute output budget, overrides the ratio
  "usd_per_million_tokens": 3.0,   // price for the $-saved estimate in toasts
  "min_chars": 480,                // min selection length before ⌃⌥K does anything
  "nudge_min_chars": 900,          // min field length before the background nudge looks
  "nudge_min_saved_tokens": 80,    // don't nudge unless at least this many tokens are saveable
  "nudge_cooldown_seconds": 480,   // per-trace cooldown between nudges
  "max_single_pass_tokens": 1200,  // prose above this is chunked so output isn't truncated
  "clipboard_cmd": ["/usr/bin/pbcopy"],  // command that receives the compacted text on stdin
  "hotkey_keycode": 40,            // Carbon key code (kVK_ANSI_K)
  "hotkey_modifiers": 6144         // modifier bitmask (⌃⌥, 0x1800)
}
```

The `HALEN_RC_CLIPBOARD_CMD`, `HALEN_RC_TARGET_RATIO`, `HALEN_RC_TARGET_TOKENS`
and `HALEN_RC_MODE` environment variables override the corresponding keys (used
by the test harness).

## Reporting

Token counts are estimated at roughly 4 characters per token — enough to size
requests and report savings. Each compaction toast shows
`N → M tokens · X× smaller (−P%)` plus a running session token total and, once
it crosses half a cent, an estimated dollar saving at `usd_per_million_tokens`.
On shutdown the plugin logs how many traces it compacted and the approximate
total tokens saved for the session. Nothing leaves your Mac.
