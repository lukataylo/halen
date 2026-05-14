# Snippet Expander

> Plugin id: `com.halen.snippet-expander` · Category: Productivity · Code:
> [`Sources/Halen/Features/SnippetExpander/`](../../../Sources/Halen/Features/SnippetExpander/)

A TextExpander-style sentinel trigger, with a twist: snippets can be
**AI-backed**, where the snippet's stored value is a system prompt sent
to Gemma 4 with the surrounding text as context.

## Trigger pattern

Same trigger as TypoFixer's, with one extension. On every `text.pause`:

1. Require a separator (whitespace or punctuation) at `caretOffset - 1`.
2. Walk back over the separator run.
3. Walk back over the word.
4. **Then** check if the character immediately preceding the word is the
   snippet sentinel `;` — if so, include it.

```swift
if start > 0, let preceding = character(ns, at: start - 1), preceding == ";" {
    start -= 1
}
```

That step is the load-bearing detail. Semicolons count as punctuation in
the word-boundary scan, so without an explicit fold-in step the scanner
would stop *after* the `;` and never see the trigger. With it, typing
`;sig.` correctly identifies `;sig` as the token to look up.

Lookup is case-insensitive (`SnippetStore.snippet(for:)` does
`.lowercased()` compare on both sides). A 3-second `recentWrites`
suppression list prevents the expansion from re-triggering on the AX
write-back's own `text.pause`.

## The three snippet kinds

Defined in
[`Snippet.swift`](../../../Sources/Halen/Features/SnippetExpander/Snippet.swift):

```swift
enum Kind: String, Codable, Sendable {
    case staticText
    case dynamic
    case ai
}
```

### Static

`value` is the literal text to insert. Instant — single
`caretObserver.replaceRange(...)` call.

### Dynamic

`value` is a token name resolved at expansion time in
`SnippetExpander.dynamicValue(for:)`:

| Token   | Computed value                  | Format             |
|---------|---------------------------------|--------------------|
| `today` | Current local date              | `EEEE d MMMM yyyy` |
| `time`  | Current local time              | `HH:mm`            |

(Easy to extend — the switch is one method.)

### AI

`value` is a system prompt. Expansion is two-step:

1. Immediately replace the trigger with the placeholder `[…]` so the user
   sees the snippet was recognised:

   ```swift
   let placeholder = "[…]"
   applyReplacement(placeholder, at: tokenRange, trigger: snippet.trigger)
   let placeholderRange = NSRange(location: tokenRange.location, length: 3)
   ```

2. Grab the **500 characters immediately before the trigger** as prior
   context and POST to Gemma 4 E4B:

   ```swift
   let priorEnd = tokenRange.location
   let priorStart = max(0, priorEnd - 500)
   let priorText = ns.substring(with: NSRange(location: priorStart, length: priorEnd - priorStart))

   let prompt = """
   \(snippet.value)

   Text:
   \(priorText)
   """
   let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 300, temperature: 0.4)
   ```

   On success the placeholder is replaced with the cleaned response (trimmed
   of whitespace and surrounding quotes). On failure the placeholder is
   replaced with the original trigger token so the user can re-type it.

## Built-in snippets

Defined in
[`SnippetStore.builtins`](../../../Sources/Halen/Features/SnippetExpander/SnippetStore.swift):

| Trigger     | Kind         | Behaviour |
|-------------|--------------|-----------|
| `;sig`      | static       | `— Sent via Halen, my local writing agent` |
| `;today`    | dynamic      | Today's date, formatted `EEEE d MMMM yyyy` |
| `;time`     | dynamic      | Current local time, formatted `HH:mm` |
| `;summary`  | ai           | "Summarise the following text in three concise bullet points." |
| `;rephrase` | ai           | "Rewrite the following paragraph more concisely while keeping its meaning." |
| `;formal`   | ai           | "Rewrite the following paragraph in a more formal, professional tone." |

Built-ins can be toggled but not deleted. The store merges any
built-in the user doesn't already have on every launch, so adding a new
built-in in a release ships without overwriting user-added snippets.

## Custom snippets

`SnippetStore.addCustom(trigger:kind:value:displayName:)`:

- Trigger is normalised to lowercase, prefixed with `;` if missing, and
  stripped of any character that isn't a letter, digit, or `;`.
- Built-in triggers can't be overwritten by custom ones.
- Each entry stores: `trigger`, `kind`, `value`, `displayName`, `builtin`.

The detail view (`SnippetExpanderDetailView`) lists snippets sorted with
built-ins first, then alphabetically by trigger; add/edit/delete UI is
inline.

## Storage

File: `~/Library/Application Support/Halen/com.halen.snippet-expander/snippets.json`

```json
{
  "version": 1,
  "snippets": [
    { "trigger": ";sig", "kind": "staticText", "value": "— Sent via Halen…",
      "displayName": "Signature", "builtin": true },
    { "trigger": ";summary", "kind": "ai",
      "value": "Summarise the following text in three concise bullet points. Output only the bullets, no preamble.",
      "displayName": "Summarise prior text", "builtin": true }
  ]
}
```
