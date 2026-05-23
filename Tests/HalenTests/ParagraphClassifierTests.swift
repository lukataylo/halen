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

    /// Returns `(text, caretOffset)` so the caret lands **inside** the
    /// paragraph (not past a trailing newline — `paragraphAroundCaret`
    /// walks backward to the previous `\n` and forward to the next; a
    /// caret at `text.count` past a `\n` resolves to the empty string).
    private func paragraphInput(_ body: String) -> (text: String, caretOffset: Int) {
        // Repeat the body so the paragraph is comfortably over the default
        // `minLength` (60) even when tests dial it down.
        let stretched = String(repeating: body + " ", count: 4)
            .trimmingCharacters(in: .whitespaces)
        let text = "\n\(stretched)\n"
        // Caret points to the last char of the paragraph itself — clearly
        // *inside* the line, not past the trailing newline.
        return (text, stretched.count + 1) // +1 for the leading "\n"
    }

    /// Drain the classifier's settled work — settle delay is ~0 in tests
    /// but the task hop is still async; give the scheduler enough time on
    /// a loaded CI runner.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// First time a paragraph is seen, it should be classified. Second time
    /// (identical content, no intervening evictions), it should be skipped —
    /// dedup hit.
    func testSameParagraphRunsOnceThenDedups() async {
        let classifier = ParagraphClassifier(
            minLength: 20, settleDelay: 0.0, maxCacheSize: 16)
        let (text, caret) = paragraphInput("This paragraph reads as irritated and short.")

        actor Counter { var hits = 0; func bump() { hits += 1 } }
        let counter = Counter()

        classifier.schedule(text: text, caretOffset: caret,
                             classify: { _ in await counter.bump() })
        await drain()
        classifier.schedule(text: text, caretOffset: caret,
                             classify: { _ in await counter.bump() })
        await drain()

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

        let (frequentText, frequentCaret) =
            paragraphInput("This is the paragraph the user keeps editing.")
        let frequentParagraph = frequentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prime the frequent paragraph.
        classifier.schedule(text: frequentText, caretOffset: frequentCaret,
                             classify: { p in await tracker.record(p) })
        await drain()

        // Touch fresh paragraphs interleaved with re-touches of `frequent`.
        // Each re-touch should DEDUP (no new classification) but should also
        // move `frequent` to the most-recent slot in the LRU — so it
        // survives the `cap` × 2 fresh paragraphs that would have evicted it
        // under strict FIFO.
        for i in 0..<(cap * 2) {
            let (freshText, freshCaret) =
                paragraphInput("Filler paragraph number \(i) for cache pressure.")
            classifier.schedule(text: freshText, caretOffset: freshCaret,
                                 classify: { p in await tracker.record(p) })
            await drain()
            classifier.schedule(text: frequentText, caretOffset: frequentCaret,
                                 classify: { p in await tracker.record(p) })
            await drain()
        }

        // Final re-touch — the frequent paragraph should STILL be cached, so
        // this should not produce a new classification.
        classifier.schedule(text: frequentText, caretOffset: frequentCaret,
                             classify: { p in await tracker.record(p) })
        await drain()

        let seen = await tracker.seen
        let frequentHits = seen.filter { $0 == frequentParagraph }
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
        let text = "\nToo short\n"
        // Caret inside the body, not past the trailing newline.
        let caret = text.count - 1

        classifier.schedule(text: text, caretOffset: caret,
                             classify: { _ in await counter.bump() })
        await drain()

        let n = await counter.n
        XCTAssertEqual(n, 0, "paragraph below minLength must not classify")
    }
}
