import XCTest
@testable import Halen

/// Behavioural tests for `ParagraphClassifier`'s LRU dedup. The class's other
/// responsibilities (settle debounce, paragraph extraction) are covered
/// implicitly via SentimentGuard's integration; what's high-value to test
/// directly is the dedup cache, where a regression would manifest as either
/// (a) the same paragraph re-classifying on every keystroke (cache miss when
/// it shouldn't) or (b) a stale finding sticking around past `maxCacheSize`
/// (eviction broken).
@MainActor
final class ParagraphClassifierTests: XCTestCase {

    /// Helper — feed a paragraph long enough to clear `minLength`. The
    /// classifier reads `paragraphAroundCaret`, so we make sure the paragraph
    /// is the only thing in `text`.
    private func paragraph(_ s: String) -> String {
        // Repeat until > 60 chars (default minLength). One long sentence is
        // enough; we ensure it sits between two newlines so paragraph
        // extraction doesn't pull anything else in.
        let body = String(repeating: s + " ", count: 4)
        return "\n\(body.trimmingCharacters(in: .whitespaces))\n"
    }

    /// First time a paragraph is seen, it should be classified. Second time
    /// (identical content, no intervening evictions), it should be skipped —
    /// dedup hit.
    func testSamePaIdenticalRunsOnceThenSkips() async {
        let classifier = ParagraphClassifier(
            minLength: 20, settleDelay: 0.0, maxCacheSize: 16)
        let text = paragraph("This paragraph reads as irritated and short.")

        actor Counter { var hits = 0; func bump() { hits += 1 } }
        let counter = Counter()

        // First run — should hit.
        classifier.schedule(
            text: text, caretOffset: text.count,
            classify: { _ in await counter.bump() })
        try? await Task.sleep(for: .milliseconds(50))

        // Second run with same content — should be deduplicated.
        classifier.schedule(
            text: text, caretOffset: text.count,
            classify: { _ in await counter.bump() })
        try? await Task.sleep(for: .milliseconds(50))

        let hits = await counter.hits
        XCTAssertEqual(hits, 1, "identical paragraph should classify exactly once")
    }

    /// LRU semantics: when the user keeps editing a paragraph (touching it
    /// repeatedly), it should stay cached even after `maxCacheSize` *other*
    /// paragraphs go through — strict FIFO would have evicted it. This is
    /// the difference between FIFO and LRU that motivated the change.
    func testLRUTouchKeepsFrequentlyEditedParagraphCached() async {
        let cap = 4
        let classifier = ParagraphClassifier(
            minLength: 20, settleDelay: 0.0, maxCacheSize: cap)

        actor Tracker {
            var seen: [String] = []
            func record(_ s: String) { seen.append(s) }
        }
        let tracker = Tracker()

        let frequent = paragraph("This is the paragraph the user keeps editing.")

        // Prime the frequent paragraph.
        classifier.schedule(text: frequent, caretOffset: frequent.count,
                             classify: { p in await tracker.record(p) })
        try? await Task.sleep(for: .milliseconds(30))

        // Touch a series of fresh paragraphs, interleaved with re-touches
        // of `frequent`. Each re-touch should DEDUP (no new classification)
        // but should also move `frequent` to the most-recent slot in the LRU.
        for i in 0..<(cap * 2) {
            let fresh = paragraph("Filler paragraph number \(i) for cache pressure.")
            classifier.schedule(text: fresh, caretOffset: fresh.count,
                                 classify: { p in await tracker.record(p) })
            try? await Task.sleep(for: .milliseconds(30))
            // Re-touch the frequent paragraph between every other filler.
            classifier.schedule(text: frequent, caretOffset: frequent.count,
                                 classify: { p in await tracker.record(p) })
            try? await Task.sleep(for: .milliseconds(30))
        }

        // Final re-touch — the frequent paragraph should STILL be cached, so
        // this should not produce a new classification.
        classifier.schedule(text: frequent, caretOffset: frequent.count,
                             classify: { p in await tracker.record(p) })
        try? await Task.sleep(for: .milliseconds(50))

        let seen = await tracker.seen
        let frequentHits = seen.filter { $0 == frequent.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(frequentHits.count, 1,
                       "frequently-touched paragraph should classify exactly once across all re-touches")
    }

    /// Below `minLength`, a paragraph is short noise — should never reach
    /// the dedup cache or the classify closure.
    func testShortParagraphSkipped() async {
        let classifier = ParagraphClassifier(
            minLength: 100, settleDelay: 0.0)

        actor Counter { var n = 0; func bump() { n += 1 } }
        let counter = Counter()
        let tiny = "\nToo short\n"

        classifier.schedule(text: tiny, caretOffset: tiny.count,
                             classify: { _ in await counter.bump() })
        try? await Task.sleep(for: .milliseconds(50))

        let n = await counter.n
        XCTAssertEqual(n, 0, "paragraph below minLength must not classify")
    }
}
