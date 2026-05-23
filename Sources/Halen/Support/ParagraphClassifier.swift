import Foundation

/// Shared scaffolding for "wait for the user to stop typing, then classify the
/// paragraph at the caret" — the SentimentGuard / BurnoutCopilot pattern.
///
/// Owns three responsibilities so each plugin doesn't reinvent them:
///
///  1. **Settle debounce** — every `schedule(...)` call resets a `settleDelay`
///     timer; the work only fires when typing genuinely stops, so Gemma isn't
///     run mid-sentence.
///  2. **Paragraph extraction** — pulls the line-bounded paragraph around the
///     caret via `paragraphAroundCaret`, gates it on `minLength`, and runs an
///     optional per-call `eligibility` predicate (e.g. "needs sentence-ending
///     punctuation", "not in app cooldown").
///  3. **Hash-based dedup** — a bounded FIFO of SHA-256 fingerprints means an
///     identical paragraph isn't re-classified, but the cache can't grow
///     without bound. FIFO (not random) eviction so behaviour is predictable.
///
/// Anything plugin-specific — the actual Gemma prompt, what to do with the
/// label, persistent allowlists — lives in the per-call `classify` closure.
@MainActor
final class ParagraphClassifier {
    private let minLength: Int
    private let settleDelay: TimeInterval
    private let maxCacheSize: Int

    private var task: Task<Void, Never>?
    private var seenHashes: Set<String> = []
    private var seenOrder: [String] = []   // FIFO eviction (oldest at index 0)

    init(minLength: Int = 60,
         settleDelay: TimeInterval = 1.0,
         maxCacheSize: Int = 256) {
        self.minLength = minLength
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
        guard paragraph.count > minLength, eligibility(paragraph) else { return }

        let hash = sha256Hex(paragraph)
        guard !seenHashes.contains(hash) else { return }
        seenHashes.insert(hash)
        seenOrder.append(hash)
        if seenHashes.count > maxCacheSize {
            let evict = seenOrder.removeFirst()
            seenHashes.remove(evict)
        }

        await classify(paragraph)
    }
}
