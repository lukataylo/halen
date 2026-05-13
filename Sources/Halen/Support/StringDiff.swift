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
