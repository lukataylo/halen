import Foundation

/// Shared scaffolding for "wait for the user to stop typing, then classify the
/// paragraph at the caret" — the SentimentGuard / ClarityChecker pattern.
///
/// Owns three responsibilities so each plugin doesn't reinvent them:
///
///  1. **Settle debounce** — every `schedule(...)` call resets a `settleDelay`
///     timer; the work only fires when typing genuinely stops, so the
///     classifier isn't run mid-sentence.
///  2. **Paragraph extraction** — pulls the line-bounded paragraph around the
///     caret via `paragraphAroundCaret`, gates it on `minLength`, and runs an
///     optional per-call `eligibility` predicate (e.g. "needs sentence-ending
///     punctuation", "not in app cooldown").
///  3. **Hash-based dedup** — a bounded LRU of SHA-256 fingerprints means an
///     identical paragraph isn't re-classified. LRU (touched-most-recently
///     stays) instead of strict FIFO so a paragraph the user keeps editing
///     stays cached even past `maxCacheSize` intervening writes.
///
/// Anything plugin-specific — the actual classification prompt, what to do
/// with the label, persistent allowlists — lives in the per-call `classify`
/// closure.
@MainActor
final class ParagraphClassifier {
    private let minLength: Int
    /// Upper bound on paragraph size in characters. A multi-KB paste is
    /// almost always something the user doesn't want classified (a code
    /// block, a quoted reply, a chunk of pasted log) — and would blow
    /// through the classifier model's 2K-token context anyway. Skipping
    /// is cheaper and friendlier than truncating.
    private let maxLength: Int
    private let settleDelay: TimeInterval
    private let maxCacheSize: Int

    private var task: Task<Void, Never>?
    /// LRU of seen paragraph hashes. Most-recently-touched at the END;
    /// eviction trims from the FRONT when the count exceeds `maxCacheSize`.
    /// An ordered array (not a linked list) is fine because the cap is
    /// small enough (256 default) that O(n) removals are sub-microsecond.
    private var seenLRU: [String] = []

    init(minLength: Int = 60,
         maxLength: Int = 4_000,
         settleDelay: TimeInterval = 1.0,
         maxCacheSize: Int = 256) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.settleDelay = settleDelay
        self.maxCacheSize = maxCacheSize
    }
    // Default `settleDelay` lowered from 2.5 s → 1.0 s now that the
    // `.classifier` tier (Qwen 0.5B) keeps total classification well under
    // a second warm. Combined: text-pause → popover lands in roughly 2 s.
    // Per-plugin overrides (StyleGuide uses 1.5) still apply.

    /// Schedule a classification. The closures are captured per call, so each
    /// schedule can carry its own context (the focused-app bundle id at the
    /// time of typing, for example) without changing the classifier's API.
    /// Calling `schedule` again before the prior settle elapses cancels the
    /// pending work — only the most-recent paragraph gets classified.
    func schedule(text: String,
                  caretOffset: Int,
                  eligibility: @escaping @MainActor (String) -> Bool = { _ in true },
                  classify: @escaping @MainActor (String) async -> Void) {
        task?.cancel()
        task = Task { @MainActor [weak self, settleDelay] in
            try? await Task.sleep(for: .seconds(settleDelay))
            guard let self, !Task.isCancelled else { return }
            await self.run(text: text, caretOffset: caretOffset,
                           eligibility: eligibility, classify: classify)
        }
    }

    /// Cancel any pending settle. Plugins should call from `stop()`.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(text: String, caretOffset: Int,
                     eligibility: @MainActor (String) -> Bool,
                     classify: @MainActor (String) async -> Void) async {
        let paragraph = paragraphAroundCaret(text: text, caretOffset: caretOffset)
        guard paragraph.count > minLength, paragraph.count <= maxLength, eligibility(paragraph) else {
            if paragraph.count > maxLength {
                Log.debug("ParagraphClassifier: skipping \(paragraph.count)-char paragraph (> \(maxLength))")
            }
            return
        }

        let hash = sha256Hex(paragraph)
        // LRU touch: if we've seen this hash, move it to the most-recent
        // slot AND skip re-classifying (the user is mid-edit on a paragraph
        // we already judged). If unseen, append + evict if over cap.
        if let existing = seenLRU.firstIndex(of: hash) {
            seenLRU.remove(at: existing)
            seenLRU.append(hash)
            return
        }
        seenLRU.append(hash)
        if seenLRU.count > maxCacheSize {
            seenLRU.removeFirst()
        }

        await classify(paragraph)
    }
}
