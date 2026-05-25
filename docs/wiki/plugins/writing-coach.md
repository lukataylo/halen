# Writing Coach

> Plugin id: `com.halen.writing-coach` · Category: Writing · Code:
> [`Sources/Halen/Features/WritingCoach/`](../../../Sources/Halen/Features/WritingCoach/)

Two paragraph-level classifiers in one plugin. Both run when you pause typing.

- **Tone** — flags hostile, irritated, passive-aggressive language. Lower-priority labels (anxious, overly corporate) opt in.
- **Clarity** — flags passive voice, run-on sentences, vague pronouns.

Each finding tints the caret indicator. Click for a popover with **Looks fine** (allowlist this paragraph) and **Rephrase** (Gemma rewrites it).

## How it works

Engines:

- [`SentimentGuard`](../../../Sources/Halen/Features/SentimentGuard/SentimentGuard.swift) — tone classifier.
- [`ClarityChecker`](../../../Sources/Halen/Features/ClarityChecker/ClarityChecker.swift) — clarity rules.

Both share the [`ParagraphClassifier`](../../../Sources/Halen/Support/ParagraphClassifier.swift) scaffold:

1. Subscribe to `text.pause`. Reset settle-debounce timer on every event.
2. After 1 second of stillness, extract the paragraph around the caret.
3. Hash the paragraph. Skip if already classified (LRU cap 256).
4. Build the prompt (rule definitions + few-shot examples + per-app tone clause + sensitivity).
5. Hand to [`InferenceRouter`](../../../Sources/Halen/Inference/RouterInferenceClient.swift). Tone uses Qwen 2.5 0.5B (`.classifier` tier, sub-100ms warm). Clarity routes to the same.
6. On a match, publish `findingDetected`. OverlayController paints the indicator severity colour.

The popover surfaces via the indicator's click handler — see [`FindingsPopover`](../../../Sources/Halen/Features/FindingsPopover.swift). Rephrase streams the rewrite into a preview pane and writes back on confirm.

## Per-app tuning

Read from [`AppToneProfileStore`](../../../Sources/Halen/Features/ToneProfiles/AppToneProfileStore.swift) (editable in Settings → App tone profiles). Slack reads "casual" so blunt phrasing isn't over-flagged. Mail reads "formal" so a brusque one-liner gets a warning.

## Detail view

Two tabs:

- **Tone** — sensitivity slider (strict / balanced / lax), built-in rules (5) + custom rules, ignored apps list, conciseness toggle.
- **Clarity** — sensitivity slider, built-in clarity rules (passive voice, run-ons, vague pronouns, etc.), suggestion mode (offer rewrite vs flag only).

## Why merged

Both run the same classifier scaffold against each settled paragraph. Two separate marketplace rows + two enable toggles + two popovers competing for the same paragraph was the surface area being trimmed. Wrapper plugin owns both engines so each keeps its rule store, sensitivity, and prompts unchanged.

A future fusion that issues one Qwen call per paragraph against a combined rule set would roughly halve per-paragraph latency. Tracked as an optimisation, not a UX change.

## Migration from before v0.3

Returning users who had `com.halen.sentiment-guard` or `com.halen.clarity-checker` enabled have Writing Coach on. Storage paths unchanged.
