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

    // MARK: - Latency budgets
    //
    // These budgets are picked to catch *regressions*, not to specify a fixed
    // contract — the absolute numbers depend on the runner. They're sized
    // generously enough to be stable on the macOS-14 GitHub runner (which is
    // noticeably slower than local Apple silicon) while still tight enough to
    // flag a real perf cliff (e.g. someone reintroducing per-call
    // `String(format:)` in `sha256Hex`, or adding a synchronous I/O hop into
    // `ParagraphClassifier.run`).
    //
    //   ParagraphClassifier.classify P50 < 5 ms / P99 < 50 ms
    //     — measures the classifier's own overhead (hashing + LRU touch +
    //       async hop), with the user-supplied `classify` closure returning
    //       instantly. A regression here means we've added work on the
    //       paragraph-settle hot path.
    //
    //   sha256Hex P50 < 100 µs on a 100-char input
    //     — guards the inline-hex encode. The pre-optimization version
    //       (`%02x` + `.joined()`) measured roughly an order of magnitude
    //       worse on the same hardware.

    /// Compute the value at percentile `p` (0…1) from an unsorted array.
    /// Uses nearest-rank: index = ceil(p * n) - 1, clamped to [0, n-1].
    private func percentile<T: Comparable>(_ samples: [T], _ p: Double) -> T {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        let idx = max(0, min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[idx]
    }

    /// Classifier overhead per `schedule` call, end-to-end from `schedule`
    /// returning through the settle hop until the no-op `classify` closure
    /// runs. `settleDelay: 0` keeps the timer out of the measurement; what
    /// remains is hashing + LRU lookup + the task hop itself.
    func testClassifyP50UnderBudget() async {
        let classifier = ParagraphClassifier(
            minLength: 20, settleDelay: 0.0, maxCacheSize: 256)

        // Warm the cache machinery once so the first sample doesn't carry
        // one-time allocator costs (Task spawn, first hash buffer alloc).
        let (warmText, warmCaret) = paragraphInput("Warmup paragraph for the classifier path.")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            classifier.schedule(text: warmText, caretOffset: warmCaret,
                                 classify: { _ in cont.resume() })
        }

        var durationsNs: [Int64] = []
        durationsNs.reserveCapacity(100)
        let clock = ContinuousClock()

        for i in 0..<100 {
            // Distinct content per iteration so the LRU treats each as a miss
            // (we want to measure the full path including the append +
            // potential eviction, not just the dedup short-circuit).
            let (text, caret) =
                paragraphInput("Test paragraph \(i) with some words for the classifier.")
            let start = clock.now
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                classifier.schedule(text: text, caretOffset: caret,
                                     classify: { _ in cont.resume() })
            }
            let elapsed = clock.now - start
            let c = elapsed.components
            let ns = c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
            durationsNs.append(ns)
        }

        let p50 = percentile(durationsNs, 0.50)
        let p99 = percentile(durationsNs, 0.99)
        let p50Ms = Double(p50) / 1_000_000
        let p99Ms = Double(p99) / 1_000_000
        print("ParagraphClassifier.schedule overhead — P50: \(p50Ms) ms, P99: \(p99Ms) ms")

        XCTAssertLessThan(p50Ms, 5.0, "classifier P50 exceeded 5 ms budget")
        XCTAssertLessThan(p99Ms, 50.0, "classifier P99 exceeded 50 ms tail budget")
    }

    /// `sha256Hex` is on the per-paragraph hot path; this guards the
    /// inline-hex encoding from regressing back to `String(format:)`.
    func testHashingP50UnderBudget() {
        // 100-char input matches the lower end of a typical paragraph; the
        // hash cost is dominated by the encode, not the SHA core, so input
        // size barely moves the number — but we keep it realistic.
        let input = String(repeating: "abcde12345", count: 10)
        XCTAssertEqual(input.count, 100)

        // Warm: one call to amortize first-touch allocator costs.
        _ = sha256Hex(input)

        var durationsNs: [Int64] = []
        durationsNs.reserveCapacity(10_000)
        let clock = ContinuousClock()

        for _ in 0..<10_000 {
            let start = clock.now
            let hex = sha256Hex(input)
            let elapsed = clock.now - start
            // Prevent the optimizer from eliding the call.
            XCTAssertEqual(hex.count, 64)
            let c = elapsed.components
            durationsNs.append(c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000)
        }

        let p50 = percentile(durationsNs, 0.50)
        let p99 = percentile(durationsNs, 0.99)
        let p50Us = Double(p50) / 1_000
        let p99Us = Double(p99) / 1_000
        print("sha256Hex(100 chars) — P50: \(p50Us) µs, P99: \(p99Us) µs")

        XCTAssertLessThan(p50Us, 100.0, "sha256Hex P50 exceeded 100 µs budget")
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
