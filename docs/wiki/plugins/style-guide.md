# Personal Style Guide

> Plugin id: `com.halen.style-guide` · Category: Writing · Code:
> [`Sources/Halen/Features/StyleGuide/`](../../../Sources/Halen/Features/StyleGuide/)

A pure rule engine — no inference. Holds the user's banned-word →
preferred-word pairs and "never use X" prohibitions; scans each settled
paragraph and surfaces matches in the shared `FindingsPopover` with
one-tap replacements.

## What it does

Watches `text.pause` events, debounces for 1.5 s (slightly longer than the
inference plugins to keep this lightweight scan from feeling jittery), and
runs `StyleRulesStore.scan` against the paragraph at the caret. Each enabled
rule contributes at most one match per scan.

A rule with a non-empty `preferred` term renders as a "Replace" finding —
clicking it rewrites the *first* word-boundary occurrence in place. A rule
with an empty `preferred` is a pure prohibition; the popover shows
"avoid this term" with no fix button.

## Built-in rules

Three widely-agreed defaults out of the box (`StyleRulesStore.builtins`):

- `utilize` → `use`
- `very unique` → `unique`
- `irregardless` → `regardless`

Everything personal is user-added. Custom rules persist to
`~/Library/Application Support/Halen/com.halen.style-guide/rules.json`.

## Word-boundary correctness

The scan respects word boundaries — banning `form` does **not** flag
`format`, banning `use` does **not** flag `user`. The relevant logic in
`StyleRulesStore.wordRange`:

```swift
let before: unichar? = found.location > 0 ? ns.character(at: found.location - 1) : nil
let after:  unichar? = afterIdx < ns.length ? ns.character(at: afterIdx) : nil
if !Self.isLetter(before) && !Self.isLetter(after) { return found }
```

Locked in by `Tests/HalenTests/StyleRulesStoreTests.swift`, which catches
the obvious regressions (substring matches, the boundary at start/end of
text, punctuation as a boundary, multi-word phrases).

Matching is case-insensitive but the *display* preserves the user's
casing — banned `form` flagged in "Form follows function" shows the
literal `Form` in the finding.

## Replace path

Clicking **Replace** re-reads the focused field's current value (the user
may have kept typing after the scan settled), re-finds the *first*
word-boundary occurrence of the banned term, and AX-writes the preferred
term in place. If the banned term has since been edited out, the
replacement is a no-op and gets logged.

```
StyleGuide: replaced "utilize" → "use" wrote=true
StyleGuide: "form" no longer in field — skipping replace
```

## Detail view

Built-in rules listed first (toggle only), then user rules below
(toggle + delete). Add-rule form takes a banned term and an optional
preferred term — leaving preferred blank creates a prohibition.

## What it does NOT do (yet)

- **Regex rules.** All matches are literal strings. Queued as a follow-up
  alongside CSV import.
- **Cross-paragraph scanning.** One paragraph at a time — the same shape
  as Sentiment Guard / Clarity Checker.
- **Style-aware rewrites.** The future plan is to feed `enabledRules`
  into Email Reply / `;rephrase` prompts ("follow these style
  rules: …"), so the user's preferences propagate to generation. Not
  wired yet.
