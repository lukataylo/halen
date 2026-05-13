# Typo Fixer

> Plugin id: `com.halen.typo-fixer` · Category: Writing · Code:
> [`Sources/Halen/Features/TypoFixer.swift`](../../../Sources/Halen/Features/TypoFixer.swift),
> [`Sources/Halen/Features/TypoStore.swift`](../../../Sources/Halen/Features/TypoStore.swift)

The simplest plugin in the system, and the one that demonstrates the full
event → AX-write-back loop end to end.

## What it does

Watches every `text.pause` event. On each one it does two things:

1. **Learns.** Diffs the new snapshot against the previous snapshot **in the
   same app** and looks for one of two correction patterns. If the user is
   visibly fixing their own typos, it records the (typo → correction) pair.
2. **Applies.** When you type a separator (whitespace or punctuation) just
   after a word that's a known typo, it replaces the word with the
   correction via `CaretObserver.replaceRange(_:with:)`.

Self-edits we just wrote, and reverts of edits we just wrote, are
suppressed and handled separately (see below).

## Trigger

```swift
guard let last = character(ns, at: caretOffset - 1),
      last.isWhitespace || last.isPunctuation else { return }
```

The canonical "user finished a word" signal across the whole codebase
(SnippetExpander reuses the same pattern). The scan then walks backward
over any trailing separator run, then backward again over the word, and
hands the lowercased token to `TypoStore.activeCorrection(for:)`.

If a correction is returned, `TypoFixer` calls `matchCase` to preserve
leading-capital input (`Frist → First`) and writes back through AX:

```swift
let range = NSRange(location: start, length: end - start)
caretObserver?.replaceRange(range, with: cased)
```

On `app.focused`, the per-app snapshot and any pending deletion are
cleared so the diffing logic doesn't span apps.

## The seeded personal typo dictionary

`TypoStore` ships with **32** built-in entries (the
`personalSeed` static dictionary). They are merged into the user's
`typos.json` on every launch — new seed entries appear without resetting,
removing a seed entry doesn't delete the user's copy. Each one is added
with `observations = activeThreshold = 2` so it's active immediately.

The seed is grouped by failure mode:

| Group | Examples |
|---|---|
| Transposed adjacent letters       | `udnerstand → understand`, `applciation → application` |
| Scrambled vowels mid-word         | `weleocme → welcome`, `prioroirty → priority` |
| Missing letters                   | `acess → access`, `frist → first` |
| Homophones / sound-alikes         | `loosing → losing`, `form → from` (context-dependent — see below) |
| Word substitutions                | `creative → create`, `hardboard → artboard` |
| Run-on / missing-space compounds  | `alot → a lot`, `littlebit → a little bit`, `msyelf → myself` |
| Extra/double letters mid-word     | `scenrarios → scenarios`, `whhats → whats`, `desperatley → desperately` |

A small `halendemo → HALEN AUTO-LEARN ACTIVE` entry is added on first launch
so demos have something obvious to trigger on.

### Context-dependent entries

Five seed entries (`form`, `sweet`, `creative`, `complements`, `hardboard`)
are real words with legitimate uses. The safety net is **revert-on-undo
demotion**: if the user backspaces and retypes the original word within 60 s
of an auto-fix, the entry is silently removed from the dictionary. So
"creative" misfiring as "create" self-corrects after one occurrence.

## Auto-learn behaviour

The learning loop lives in `TypoFixer.learn(app:old:new:)` and runs against
the diff between the previous snapshot for the same bundle id and the
current one.

### Direct substitution

A single contiguous region changed in one snapshot tick — typically a
double-click + retype. `diff.isSubstitution` is true and both sides look
like words.

### Delete-then-retype within 30 seconds

Two-step pattern:

1. A pause snapshot contains a pure deletion of a word-shaped token. A
   `PendingDeletion { deletedWord, position, timestamp }` is recorded
   per-app.
2. A later pause snapshot contains a pure insertion of a word-shaped token
   **at the same position** within 30 seconds. The (deleted, inserted) pair
   is treated as a correction.

```swift
if diff.isPureInsertion, looksLikeWord(diff.newText),
   let pending = pendingDeletions[app],
   Date().timeIntervalSince(pending.timestamp) < 30,
   diff.positionInNew == pending.position {
    tryRecordCorrection(typo: pending.deletedWord, correction: diff.newText)
    pendingDeletions.removeValue(forKey: app)
}
```

### Quality filters

`tryRecordCorrection` rejects pairs that look like noise:

- typo / correction must each pass `looksLikeWord`
- case-folded forms must differ
- length delta `|typo.count - correction.count|` ≤ 3
- Levenshtein distance `0 < dist ≤ 3`

It also de-duplicates against `recentSelfEdits` (corrections we just
wrote in the last 3 s) to avoid learning our own auto-fixes back.

## Revert-on-undo demotion

A 60 s rolling list of `recentAutoFixes`. When a candidate correction comes
through that looks like the **inverse** of one in the list, the original
auto-fix entry is removed from the store via `TypoStore.demote(typo:)` and
the candidate is *not* learned. Logs:

```
TypoFixer: user reverted auto-fix "creative" → "create" — demoting entry
```

This is the entire user-facing recovery mechanism: there's no "undo last
fix" command — just type past the auto-fix, then change it back, and the
entry is gone.

## Activation threshold

Auto-learned entries are tracked from the first observation but not
auto-applied until `observations >= activeThreshold (= 2)`. The second
identical correction in any app promotes the entry. User-added entries
(from the detail view) skip the warm-up and are active immediately.

## Detail view

`TypoFixerDetailView` (referenced from `TypoFixer.makeDetailView()`) lists
the dictionary sorted by `lastSeen` descending, exposes Add / Remove /
Reset, and tags built-in entries.

## Storage

File: `~/Library/Application Support/Halen/typos.json`. Pretty-printed,
sorted keys, hand-editable. Shape:

```json
{
  "version": 1,
  "entries": {
    "udnerstand": {
      "correction": "understand",
      "observations": 2,
      "firstSeen": "2026-05-01T09:14:22Z",
      "lastSeen":  "2026-05-12T18:02:11Z"
    }
  }
}
```

Note: this store lives at the **top-level** Halen support dir, not under
`com.halen.typo-fixer/`, because it predates the per-plugin storage
convention.
