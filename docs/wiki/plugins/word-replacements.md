# Word Replacements

> Plugin id: `com.halen.word-replacements` · Category: Writing · Code:
> [`Sources/Halen/Features/WordReplacements/`](../../../Sources/Halen/Features/WordReplacements/)

Two replacement engines packaged as one plugin.

- **Auto typos** — learns from how you correct yourself. Replaces a known typo inline when you finish the word. Demoted permanently if you backspace and retype.
- **Preferences** — your banned-word → preferred-word rules. Scans every paragraph. One tap to swap.

## Auto-typos

Engine: [`TypoFixer`](../../../Sources/Halen/Features/TypoFixer/TypoFixer.swift).

Learns by diffing the field's text against the previous snapshot per app. Two patterns count as a correction:

1. **Direct substitution** — `teh` deleted, `the` typed in its place.
2. **Delete-then-retype** — `teh` deleted, no replacement, then `the` typed within 30 seconds at the same position.

Filters:

- Edit distance ≤ 3.
- Length difference ≤ 3.
- Both sides look like words (letters, ≥ 2 chars).
- Lowercased forms differ.

Each observation increments the typo's counter. The threshold (default: 3 observations) is user-tunable in the detail view. Below it the typo is "learned but inactive"; at or above it gets applied automatically.

Undo: backspace + retype within 60 seconds of an auto-fix demotes the entry forever.

Storage: `~/Library/Application Support/Halen/typos.json`. Pre-seeded with 32 common slips.

## Preferences (style guide)

Engine: [`StyleGuide`](../../../Sources/Halen/Features/StyleGuide/StyleGuide.swift).

A pure rule engine — no inference. Three rule kinds:

- **Literal** — case-insensitive word-bounded match. `utilize` → `use`.
- **Regex** — your pattern, your replacement.
- **Prohibition** — flag without replacement. "Don't use X."

Scans each settled paragraph. Matches surface in a popover with a single-tap **Replace** button. Multi-match popovers list every rule that fired with its own replace button.

Storage: `~/Library/Application Support/Halen/com.halen.style-guide/rules.json`. CSV import supported in the detail view.

## Detail view

Two tabs:

- **Auto-typos** — sensitivity slider, the learned dictionary with promote/demote controls, manual add.
- **My preferences** — rule list, add-rule form, CSV import/export.

## Why merged

The two engines have different UX patterns:

- Typo Fixer is silent inline. High confidence (you've made the correction yourself before), low ceremony.
- Style Guide is popover-with-button. Lower confidence (user-defined rule, might not always apply), explicit consent.

Sharing a single event subscription would force one UX onto both. The merge is a wrapper plugin that owns both engines and routes events to both — one row in the marketplace, two distinct UX patterns underneath.

## Migration from before v0.3

Returning users who had `com.halen.typo-fixer` or `com.halen.style-guide` enabled have Word Replacements on. Either-on means on. Both stored as off means off. Storage paths unchanged so settings carry over.
