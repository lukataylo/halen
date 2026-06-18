---
description: View and change how Halen compacts this project's context on-device (frequency, type, and the major tradeoffs)
---

# Configure Halen local compaction

You are helping the user tune the **Halen local-compaction** plugin, which
compacts Claude Code's context using Halen's on-device model instead of the
cloud. The settings live in `${CLAUDE_PLUGIN_ROOT}/config.json`.

Do this:

1. Read `${CLAUDE_PLUGIN_ROOT}/config.json` and show the user the current
   values in a short table.
2. Explain the knobs in plain language (only the ones they ask about — don't
   lecture):

   - **frequency** — *when* the local compaction runs.
     - `"auto"` (default): on both manual `/compact` and automatic compaction.
     - `"manual"`: only when the user runs `/compact`.
   - **min_tokens** — skip compaction for transcripts smaller than this
     (default `6000`). Raise it to compact less often; lower it to compact
     sooner.
   - **type** — *how* it compacts (the headline tradeoff):
     - `"extractive"` (default): the local model picks which conversation turns
       to keep; the summary is rebuilt **verbatim** from your real turns, so it
       can never invent content. Most faithful.
     - `"abstractive"`: the model rewrites the conversation into a tight
       briefing. Smaller output, but faithfulness depends on the model.
   - **target_keep_ratio** — fraction of tokens to aim to keep (`0.1`–`0.95`,
     default `0.4`). Lower = more aggressive compaction.
   - **target_tokens** — a hard output budget in tokens. When `> 0` it
     overrides `target_keep_ratio`.
   - **preserve** — things to always keep: any of `"code"`, `"decisions"`,
     `"final_answers"`.
   - **inject_on_resume** — re-inject the saved local summary when the session
     resumes (default `true`).
   - **model_tier** — which local Halen model runs the compaction:
     `"small"`, `"medium"` (default) or `"large"`. Larger = better summaries,
     slower.

3. Ask what they'd like to change, then write the updated JSON back to
   `${CLAUDE_PLUGIN_ROOT}/config.json`, preserving the keys they didn't touch.
   Validate values against the ranges above before writing.

4. Confirm the change and remind them it takes effect on the next compaction —
   no restart needed.
