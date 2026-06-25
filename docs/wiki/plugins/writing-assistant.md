# Writing Assistant

> Plugin id: `com.halen.writing-assistant` · Category: Writing · Code:
> [`Sources/Halen/Features/`](../../../Sources/Halen/Features/)
>
> Runs **in-process** inside the menubar binary. One marketplace row, one
> on/off switch, on by default. No hotkey of its own — its engines react
> to you typing.

Halen's single Grammarly-esque writing surface. It fixes typos and flags
tone and clarity — two engines under one plugin so there's one toggle and
one detail panel instead of separate rows competing for the same paragraph.

## The engines

| Engine | When it fires | UX |
|---|---|---|
| **Corrections** | As you finish a word / settle a paragraph | Silent inline typo swap; popover-with-button for your preferred-word rules. |
| **Clarity & tone** | After ~1 s of stillness | Tints the caret indicator. Click for **Looks fine** / **Rephrase**. Per-app target tones flag the wrong register. |

### Corrections

Two replacement engines:

- **Auto typos** ([`TypoFixer`](../../../Sources/Halen/Features/TypoFixer/TypoFixer.swift))
  learns from how you correct yourself and replaces a known typo inline
  when you finish the word. Backspace + retype within 60 s of an auto-fix
  demotes the entry forever. Pre-seeded with 32 common slips.
- **Preferences** ([`StyleGuide`](../../../Sources/Halen/Features/StyleGuide/StyleGuide.swift))
  is a pure rule engine — no inference. Literal, regex, and prohibition
  rules scan each settled paragraph; matches surface in a popover with a
  single-tap **Replace** button.

### Clarity & tone

Two paragraph-level classifiers, both built on the
[`ParagraphClassifier`](../../../Sources/Halen/Support/ParagraphClassifier.swift)
scaffold:

- **Tone** ([`SentimentGuard`](../../../Sources/Halen/Features/SentimentGuard/SentimentGuard.swift))
  flags hostile, irritated, passive-aggressive language. Lower-priority
  labels (anxious, overly corporate) opt in.
- **Clarity** ([`ClarityChecker`](../../../Sources/Halen/Features/ClarityChecker/ClarityChecker.swift))
  flags passive voice, run-on sentences, and vague pronouns.

Tone routes to a dedicated Qwen 2.5 0.5B model (`.classifier` tier,
sub-100 ms warm); clarity routes the same way. On a match the plugin
publishes `findingDetected` and the caret indicator paints the severity
colour. **Rephrase** streams a Gemma rewrite into a preview pane and
writes back on confirm. Per-app tone profiles keep Slack's bluntness from
over-flagging while Mail stays formal.

## Detail view

Tabs for each engine: auto-typo sensitivity and learned dictionary; your
preferred-word rules with CSV import/export; tone sensitivity, rules,
per-app target tones, and ignored apps; clarity sensitivity and suggestion
mode.

## Migration

Returning users who had any of the old `com.halen.typo-fixer`,
`com.halen.style-guide`, `com.halen.sentiment-guard`,
`com.halen.clarity-checker`, `com.halen.word-replacements`,
`com.halen.writing-coach`, or `com.halen.autocomplete` plugins enabled
get Writing Assistant on. Storage paths are unchanged, so learned typos,
rules, and tone profiles carry over.
