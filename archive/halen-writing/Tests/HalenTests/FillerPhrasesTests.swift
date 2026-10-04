import XCTest
@testable import Halen

/// `FillerPhrases.scan` is the zero-cost regex-y scan Sentiment Guard runs
/// alongside the tone classifier — conciseness isn't a tone, so it can't
/// share the single-label classifier prompt. Pure function: text in, list
/// of matches out. Locks the case-insensitive contract and ordering.
final class FillerPhrasesTests: XCTestCase {

    /// Phrases match regardless of case in the user's text.
    func testScanIsCaseInsensitive() {
        let hits = FillerPhrases.scan("In Order To get there, I had to wait.")
        XCTAssertTrue(hits.contains(where: { $0.phrase == "in order to" }),
                      "Case-insensitive match on 'in order to' failed")
    }

    /// Multiple distinct phrases are returned in the order they appear in
    /// the text — the UI renders them in that order, so the ordering is
    /// part of the contract.
    func testScanReturnsHitsInTextOrder() {
        let hits = FillerPhrases.scan(
            "Due to the fact that we had to wait, in order to finish in a timely manner.")
        let phrases = hits.map(\.phrase)
        guard let dueIdx = phrases.firstIndex(of: "due to the fact that"),
              let orderIdx = phrases.firstIndex(of: "in order to"),
              let timelyIdx = phrases.firstIndex(of: "in a timely manner") else {
            return XCTFail("Missing expected matches: \(phrases)")
        }
        XCTAssertLessThan(dueIdx, orderIdx)
        XCTAssertLessThan(orderIdx, timelyIdx)
    }

    /// Each phrase contributes at most one match per scan — the popover
    /// would be noisy otherwise, and conciseness suggestions for the same
    /// phrase twice are functionally identical.
    func testScanDedupesPerPhrase() {
        let twice = "In order to get there, in order to make it on time."
        let hits = FillerPhrases.scan(twice).filter { $0.phrase == "in order to" }
        XCTAssertEqual(hits.count, 1, "Repeated phrase must produce only one match")
    }

    /// Clean text returns an empty list — no false positives on plain prose.
    func testScanIgnoresPlainProse() {
        let hits = FillerPhrases.scan("The cat sat on the mat. It was warm.")
        XCTAssertTrue(hits.isEmpty,
                      "Plain prose should produce no filler matches, got \(hits.map(\.phrase))")
    }

    /// The suggestion attached to each match must match the dictionary
    /// entry — the rewrite UI shows it verbatim, so a drift here would
    /// surface as a misleading suggestion.
    func testSuggestionMatchesDictionary() {
        let hits = FillerPhrases.scan("Each and every member showed up.")
        let match = hits.first(where: { $0.phrase == "each and every" })
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.suggestion, "every",
                       "Suggestion for 'each and every' is 'every' in the dictionary")
    }

    /// Empty input returns an empty result without throwing.
    func testEmptyTextReturnsEmpty() {
        XCTAssertTrue(FillerPhrases.scan("").isEmpty)
    }
}
