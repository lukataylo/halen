# Sentiment Guard

> Plugin id: `com.halen.sentiment-guard` · Category: Writing · Code:
> [`Sources/Halen/Features/SentimentGuard.swift`](../../../Sources/Halen/Features/SentimentGuard.swift),
> [`Sources/Halen/Features/SentimentRulesStore.swift`](../../../Sources/Halen/Features/SentimentRulesStore.swift)

A "would you really send that?" popover, driven by a local Gemma 4 model
(`.medium` tier) running on every paused draft that looks like a message.

## Trigger gate

Subscribes to `text.pause`. To save Gemma round-trips on every keystroke,
two gates run before classification:

```swift
guard text.count > 60 else { return }
guard text.contains(where: { $0 == "." || $0 == "?" || $0 == "!" }) else { return }
```

So the user has typed at least ~60 chars **and** at least one
sentence-ending punctuation mark. The text is then windowed to ~800 chars
centred on the caret (`windowAroundCaret(text:offset:radius: 400)`).

## Hash-based de-duplication

The windowed text is hashed with SHA-256:

```swift
let hash = sha256Hex(windowed)
if approvedHashes.contains(hash) { return }
if classifiedHashes[hash] != nil { return }
```

- `approvedHashes` is a `Set<String>` persisted to disk: anything the user
  has marked "Looks fine" never re-flags, across sessions.
- `classifiedHashes` is a session-only `[String: String]` so the same draft
  re-classified mid-edit doesn't burn another inference call.

## Dynamic rules-based prompt

The classification prompt is assembled at runtime from the enabled rules
in `SentimentRulesStore`:

```swift
let categoriesBlock = enabled
    .map { "- \($0.label.lowercased()): \($0.prompt)" }
    .joined(separator: "\n")
let prompt = """
You are a tone classifier. Categorise the tone of the following text as one of these labels:
\(categoriesBlock)
- neutral: the text doesn't strongly match any of the above

Reply with ONLY the matching label, lowercase, no punctuation, no preamble.

Text: \"\"\"\(windowed)\"\"\"
"""
```

Request parameters: `tier: .medium`, `maxTokens: 16`, `temperature: 0.1`.
The router serves `.medium` from whichever backend is available (Apple
Foundation Models, the bundled Gemma 4 model, or Ollama's `gemma4:e4b`).
Adding or toggling a rule changes the prompt on the next pause — no restart
needed.

Gemma's response is normalised (lowercased, trimmed of punctuation, first
word taken) and matched against the lowercase rule labels. A match
surfaces the popover; "neutral" or any unrecognised label does nothing.

## Built-in rules

Defined in `SentimentRulesStore.builtins`:

| Id | Label | Default | Prompt fragment | Colour |
|---|---|---|---|---|
| `hostile`            | Hostile             | on  | "the text reads as hostile, aggressive, threatening, or angry at someone" | red |
| `irritated`          | Irritated           | on  | "the text reads as irritated, frustrated, sharp, or short with the reader" | orange |
| `passive_aggressive` | Passive-aggressive  | off | "subtle hostility, sarcasm, backhanded compliments, or pointed politeness" | yellow |
| `anxious`            | Anxious             | off | "anxious, overly apologetic, self-deprecating, or anxious to please" | blue |
| `overly_corporate`   | Overly corporate    | off | "overly corporate, jargon-laden, or hollow business-speak" | gray |

Built-ins can be toggled but not deleted. The store seeds any built-in the
user doesn't already have on every launch — preserves user toggles, adds
new rules shipped in a later version.

### Custom rules

The detail view (`SentimentGuardDetailView`) lets the user add custom
rules with a label, a prompt fragment, and a colour. Custom rules can be
deleted. Internally they get an id like `<slug>_<6-char-uuid>` so labels
don't collide.

## The popover

When a draft matches an enabled rule, a borderless `NSPanel` (360 × 170)
opens anchored near the caret — read from `lastCaretRect` updated on every
`caret.moved`. If no caret rect is known yet, it falls back to the bottom
right of the main screen.

Layout (`SentimentGuardPopup`):

- `exclamationmark.bubble.fill` icon tinted by the rule's colour name
- "This reads as **<label>**"
- A 3-line, 180-char preview of the windowed text
- Two buttons:
  - **Looks fine** — calls `approve(hash:)` which inserts the hash into
    `approvedHashes` and saves the file
  - **Rephrase via Gemma 4** — calls `rephrase(originalText:)` which
    sends a "rewrite calmer, keep intent and length" prompt to Gemma 4
    E4B and **puts the rewrite on the clipboard** (`NSPasteboard.general
    .setString`). The original text is *not* mutated — paste-it-yourself
    is the safety hatch.

Auto-dismiss after 12 seconds. Closing the panel cancels the timer.

```swift
dismissTask = Task { @MainActor [weak self] in
    try? await Task.sleep(for: .seconds(12))
    if !Task.isCancelled { self?.closePanel() }
}
```

## Per-session counters

`flaggedThisSession` is exposed to the detail view so the user can see
"this session: 3 flags, 12 approved fingerprints stored". It resets on
relaunch by design — the long-running signal is the approved-set size, not
the flag count.

## Storage

| File | Contents |
|---|---|
| `~/Library/Application Support/Halen/com.halen.sentiment-guard/rules.json`    | `{ version, rules: [...] }` — both built-in and custom rules, with per-rule `enabled` |
| `~/Library/Application Support/Halen/com.halen.sentiment-guard/approved.json` | Sorted array of SHA-256 hex digests |

Hashes are computed over the **windowed text** that was actually sent to
Gemma — so two near-identical drafts can still produce different hashes if
the surrounding context shifts. That's deliberate: the goal is "this exact
draft is fine", not "any draft containing this phrase is fine".
