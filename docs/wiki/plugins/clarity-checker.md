# Clarity Checker

> Plugin id: `com.halen.clarity-checker` · Category: Writing · Code:
> [`Sources/Halen/Features/ClarityChecker/`](../../../Sources/Halen/Features/ClarityChecker/)

A paragraph-level writing-quality scan that runs once a sentence settles.
Catches the four most common readability problems and offers a one-tap
Gemma 4 rewrite. Same `ParagraphClassifier` machinery as Sentiment Guard;
just a different prompt.

## What it does

Watches `text.pause` events. When the user settles and the paragraph at the
caret ends with `.`, `?`, or `!`, the classifier asks the local model
which of the user's enabled rules the paragraph violates. Hits surface in
the shared `FindingsPopover` with a "Rewrite via Gemma 4" action that
streams a cleaner version on top of the original.

```
text.pause ──► ParagraphClassifier ──► classifier prompt ──► [rule ids]
                  │ (settle 1.0 s,                                │
                  │  paragraph extract,                           ▼
                  │  hash dedup)                            FindingsPopover
                  └─────────────────────────────────────► (purple, "Rewrite")
```

## Built-in rules

`ClarityRulesStore.builtins`:

| id | Label | Default | What it flags |
|---|---|---|---|
| `passive_voice` | Passive voice | On | Sentences where active voice would be clearer |
| `run_on` | Run-on sentences | On | Overly long sentences that should be split |
| `dangling_modifier` | Dangling modifiers | On | Modifiers that attach to the wrong subject |
| `vague_pronoun` | Vague pronouns | On | "this/it/that" with no clear referent |
| `hedging` | Hedging language | Off | "just/sort of/I think maybe" weakening the point |

Custom rules: any label + prompt pair, added from the detail view. Stored
under `~/Library/Application Support/Halen/com.halen.clarity-checker/rules.json`.

## How the classifier prompt works

Each enabled rule becomes one line: `- <id>: <prompt>`. The model is told
to reply with a comma-separated list of the matching ids or `none`. Cap is
32 tokens (plenty for the longest possible reply: `passive_voice, run_on,
dangling_modifier, vague_pronoun, hedging`).

The reply tokens are validated against the enabled set before being
surfaced, so a hallucinated id never reaches the user. Tier is
`.classifier` — sub-second warm on Qwen 2.5 0.5B.

## Rewrite path

Clicking **Rewrite** in the popover swaps to a `.medium` tier (Gemma 4)
generation with the original paragraph and the list of flagged rules in
the prompt. The rewrite streams into the popover for review — it doesn't
auto-replace the original text. The user then copies or replaces in
place via the popover's action buttons.

## Settle + dedup

`ParagraphClassifier` provides:

- 1.0 s settle debounce (cancellable by the next keystroke)
- Paragraph extraction around the caret
- LRU dedup of seen paragraph hashes (256-entry default)
- Max-length skip (4 000 chars — pasted code/logs are silently ignored)

## Detail view

Built-in rule toggles, custom rule add/remove, session counter ("flagged
N paragraphs this session"). Built-ins can be disabled but not deleted.

## Why a popover instead of inline underlines

Inline Grammarly-style underlines would need a per-glyph AX overlay that
doesn't exist yet (tracked as UX-1.2). The caret-anchored popover is the
pragmatic v1 and keeps Clarity Checker consistent with Sentiment Guard.
