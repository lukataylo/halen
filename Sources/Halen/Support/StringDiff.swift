import Foundation

/// One-region diff between two snapshots of a text field. Computed via longest
/// common prefix + longest common suffix, then snapped outward to word
/// boundaries so single-character edits inside a word still report the
/// surrounding word (e.g., "teh " → "the " is reported as "teh" → "the",
/// not "eh" → "he").
struct StringDiff: Equatable {
    var oldText: String     // empty for a pure insertion
    var newText: String     // empty for a pure deletion
    var positionInOld: Int  // UTF-16 offset where the change begins in the old string
    var positionInNew: Int  // UTF-16 offset where the change begins in the new string

    var isPureDeletion: Bool { newText.isEmpty && !oldText.isEmpty }
    var isPureInsertion: Bool { oldText.isEmpty && !newText.isEmpty }
    var isSubstitution: Bool { !oldText.isEmpty && !newText.isEmpty }
}

func computeDiff(old: NSString, new: NSString) -> StringDiff? {
    let oldLen = old.length
    let newLen = new.length
    if oldLen == newLen, old.isEqual(to: new as String) { return nil }

    var prefix = 0
    while prefix < oldLen, prefix < newLen,
          old.character(at: prefix) == new.character(at: prefix) {
        prefix += 1
    }

    var suffix = 0
    while suffix < (oldLen - prefix), suffix < (newLen - prefix),
          old.character(at: oldLen - 1 - suffix) == new.character(at: newLen - 1 - suffix) {
        suffix += 1
    }

    // Snap the boundaries outward to word boundaries so we report the whole
    // surrounding word(s) instead of the minimal byte-level diff.
    while prefix > 0, !isSeparator(old.character(at: prefix - 1)) {
        prefix -= 1
    }
    while suffix > 0, !isSeparator(old.character(at: oldLen - suffix)) {
        suffix -= 1
    }

    // Prefix and suffix are word-snapped independently, so their regions can
    // overlap; clamp so prefix + suffix never exceeds either string's length.
    suffix = min(suffix, oldLen - prefix, newLen - prefix)

    let oldDiffLen = max(0, oldLen - prefix - suffix)
    let newDiffLen = max(0, newLen - prefix - suffix)
    let oldText = oldDiffLen > 0 ? old.substring(with: NSRange(location: prefix, length: oldDiffLen)) : ""
    let newText = newDiffLen > 0 ? new.substring(with: NSRange(location: prefix, length: newDiffLen)) : ""

    if oldText.isEmpty, newText.isEmpty { return nil }
    return StringDiff(
        oldText: oldText,
        newText: newText,
        positionInOld: prefix,
        positionInNew: prefix
    )
}

private func isSeparator(_ codeUnit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(codeUnit) else { return true }
    let ch = Character(scalar)
    return ch.isWhitespace || ch.isPunctuation
}

/// Standard Levenshtein edit distance, case-sensitive. Used as a sanity check
/// before recording a substitution as a correction candidate.
func levenshtein(_ a: String, _ b: String) -> Int {
    if a == b { return 0 }
    let s = Array(a), t = Array(b)
    let m = s.count, n = t.count
    if m == 0 { return n }
    if n == 0 { return m }
    var prev = Array(0...n)
    var curr = Array(repeating: 0, count: n + 1)
    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            let cost = s[i - 1] == t[j - 1] ? 0 : 1
            curr[j] = Swift.min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &curr)
    }
    return prev[n]
}

/// Returns a substring of `text` centred around UTF-16 `offset`, of total length up
/// to `2 * radius`. Also returns the new caret offset relative to the substring.
/// Used to cap event-bus payloads and Gemma prompts when the focused field has a
/// huge buffer (terminal scrollback, long documents).
func windowAroundCaret(text: String, offset: Int, radius: Int) -> (text: String, offset: Int) {
    let ns = text as NSString
    let len = ns.length
    if len <= radius * 2 {
        return (text, max(0, min(offset, len)))
    }
    let clamped = max(0, min(offset, len))
    let start = max(0, clamped - radius)
    let endRaw = clamped + radius
    let end = min(len, endRaw)
    let windowed = ns.substring(with: NSRange(location: start, length: end - start))
    return (windowed, clamped - start)
}

/// The paragraph immediately surrounding the caret — from the previous newline
/// (or start of text) through to the next newline (or end), trimmed. For
/// tone-style plugins (SentimentGuard, BurnoutCopilot) that should judge what
/// the user is *currently* writing, not historical text in the same field.
/// Avoids the two failure modes of `windowAroundCaret` for tone classification:
///   1. Earlier text in the buffer (an old hostile draft, a quoted reply,
///      previous unrelated paragraphs) taints the current sentence's verdict.
///   2. The window boundary lands inside a word, leaking fragments like "ity"
///      into the popup body.
func paragraphAroundCaret(text: String, caretOffset: Int) -> String {
    let ns = text as NSString
    let length = ns.length
    let caret = max(0, min(caretOffset, length))
    var start = caret
    while start > 0, ns.character(at: start - 1) != 0x0A /* \n */ {
        start -= 1
    }
    var end = caret
    while end < length, ns.character(at: end) != 0x0A {
        end += 1
    }
    return ns.substring(with: NSRange(location: start, length: end - start))
        .trimmingCharacters(in: .whitespaces)
}

/// `Character?` view of a UTF-16 code unit at `index` in `ns`. Returns `nil`
/// if the index is out of bounds or the unit is half of a surrogate pair (and
/// therefore not a valid Unicode scalar by itself). Used by trigger-detection
/// and word-boundary scans in SnippetExpander and TypoFixer.
func character(_ ns: NSString, at index: Int) -> Character? {
    guard index >= 0, index < ns.length else { return nil }
    guard let scalar = Unicode.Scalar(ns.character(at: index)) else { return nil }
    return Character(scalar)
}

/// What we consider a "word" for correction-learning purposes: 3–30 chars,
/// only letters (plus apostrophes and hyphens). Filters out single letters,
/// numbers, code identifiers, and other false-positive sources.
func looksLikeWord(_ s: String) -> Bool {
    guard s.count >= 3, s.count <= 30 else { return false }
    for ch in s {
        if ch.isLetter { continue }
        if ch == "'" || ch == "\u{2019}" || ch == "-" { continue }
        return false
    }
    return true
}
