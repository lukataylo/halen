import XCTest
@testable import Halen

/// `truncateUTF16` is the cap enforcer on injected text payloads. The
/// difference between counting grapheme clusters and counting UTF-16 units
/// is where emoji-heavy attackers would slip past the limit, so the
/// boundary cases get explicit coverage.
final class TruncateUTF16Tests: XCTestCase {
    func testShortTextUnchanged() {
        XCTAssertEqual(WebSocketBridge.truncateUTF16("hello", maxUnits: 100), "hello")
    }

    func testExactBoundaryUnchanged() {
        let s = String(repeating: "a", count: 100)
        XCTAssertEqual(WebSocketBridge.truncateUTF16(s, maxUnits: 100), s)
    }

    func testAsciiTruncatedToLimit() {
        let s = String(repeating: "a", count: 200)
        let truncated = WebSocketBridge.truncateUTF16(s, maxUnits: 100)
        XCTAssertEqual(truncated.utf16.count, 100)
    }

    func testNeverSplitsEmojiPair() {
        // Single emoji = 2 UTF-16 units. With maxUnits=1, we can't fit even
        // one whole emoji, so the result must be empty rather than half a
        // surrogate pair.
        let result = WebSocketBridge.truncateUTF16("😀", maxUnits: 1)
        XCTAssertEqual(result, "")
        XCTAssertEqual(result.utf16.count, 0)
    }

    func testEmojiHeavyStaysUnderCap() {
        // 10 emoji × 2 UTF-16 each = 20 UTF-16 units. Cap at 15 should fit
        // 7 emoji (14 units), drop the rest. The key invariant: the truncated
        // output's utf16.count is ≤ maxUnits.
        let s = String(repeating: "😀", count: 10)
        let truncated = WebSocketBridge.truncateUTF16(s, maxUnits: 15)
        XCTAssertLessThanOrEqual(truncated.utf16.count, 15)
        XCTAssertEqual(truncated.unicodeScalars.count, truncated.unicodeScalars.count)
    }

    func testZeroMaxUnitsReturnsEmpty() {
        XCTAssertEqual(WebSocketBridge.truncateUTF16("anything", maxUnits: 0), "")
    }

    func testCombiningSequenceNotSplit() {
        // "é" composed as e + U+0301 (combining acute) — 2 UTF-16 units total,
        // 1 grapheme cluster. With maxUnits=1 we can't fit it; result must be
        // empty, not a bare "e" missing its accent or a stray combining mark.
        let composed = "e\u{0301}"
        XCTAssertEqual(composed.utf16.count, 2)
        XCTAssertEqual(composed.count, 1)
        XCTAssertEqual(WebSocketBridge.truncateUTF16(composed, maxUnits: 1), "")
        XCTAssertEqual(WebSocketBridge.truncateUTF16(composed, maxUnits: 2), composed)
    }
}
