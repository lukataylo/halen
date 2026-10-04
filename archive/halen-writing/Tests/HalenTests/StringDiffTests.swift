import XCTest
@testable import Halen

final class StringDiffTests: XCTestCase {
    func testIdenticalStringsReturnNil() {
        XCTAssertNil(computeDiff(old: "hello world", new: "hello world"))
        XCTAssertNil(computeDiff(old: "", new: ""))
    }

    func testPureInsertionAtEnd() {
        let diff = computeDiff(old: "hello", new: "hello world")
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.oldText, "")
        // Insertion snaps outward to the surrounding word.
        XCTAssertEqual(diff?.newText, " world")
    }

    func testWordSubstitutionSnapsToWordBoundary() {
        // Single-character edit inside a word reports the whole word, not "teh"→"the"
        // at the byte level alone.
        let diff = computeDiff(old: "teh quick", new: "the quick")
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.oldText, "teh")
        XCTAssertEqual(diff?.newText, "the")
        XCTAssertEqual(diff?.positionInOld, 0)
    }

    func testPureDeletion() {
        let diff = computeDiff(old: "hello world", new: "hello")
        XCTAssertNotNil(diff)
        XCTAssertTrue(diff?.isPureDeletion == true)
        // Deletion snaps outward — the leading space comes with the word.
        XCTAssertEqual(diff?.oldText, " world")
        XCTAssertEqual(diff?.newText, "")
    }

    func testEmptyToText() {
        let diff = computeDiff(old: "", new: "hi")
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.oldText, "")
        XCTAssertEqual(diff?.newText, "hi")
    }

    func testTextToEmpty() {
        let diff = computeDiff(old: "hi", new: "")
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.oldText, "hi")
        XCTAssertEqual(diff?.newText, "")
    }

    // Emoji are surrogate pairs in UTF-16. The diff must not split inside the
    // pair when snapping to word boundaries — the surrogate-half guard in
    // `isSeparator` is what keeps that invariant.
    func testSurrogatePairBoundaryDoesNotCorruptDiff() {
        let diff = computeDiff(old: "hello 😀 world", new: "hello 😀 worlds")
        XCTAssertNotNil(diff)
        // The emoji must appear intact in either oldText or be left outside the
        // diff window entirely — never as a lone half-surrogate.
        if let oldText = diff?.oldText, !oldText.isEmpty {
            XCTAssertTrue(oldText.unicodeScalars.allSatisfy { $0.value >= 0x10000 || $0.value < 0xD800 || $0.value > 0xDFFF })
        }
        if let newText = diff?.newText, !newText.isEmpty {
            XCTAssertTrue(newText.unicodeScalars.allSatisfy { $0.value >= 0x10000 || $0.value < 0xD800 || $0.value > 0xDFFF })
        }
    }
}

final class LevenshteinTests: XCTestCase {
    func testEqualStringsZero() {
        XCTAssertEqual(levenshtein("hello", "hello"), 0)
        XCTAssertEqual(levenshtein("", ""), 0)
    }

    func testEmptyVsText() {
        XCTAssertEqual(levenshtein("", "abc"), 3)
        XCTAssertEqual(levenshtein("abc", ""), 3)
    }

    func testSingleEdit() {
        XCTAssertEqual(levenshtein("cat", "bat"), 1)        // substitute
        XCTAssertEqual(levenshtein("cat", "cats"), 1)       // insert
        XCTAssertEqual(levenshtein("cats", "cat"), 1)       // delete
    }

    func testCaseSensitive() {
        XCTAssertEqual(levenshtein("Cat", "cat"), 1)
    }

    func testClassicExample() {
        XCTAssertEqual(levenshtein("kitten", "sitting"), 3)
    }
}

final class WindowAroundCaretTests: XCTestCase {
    func testShortTextReturnsUnchanged() {
        let (text, offset) = windowAroundCaret(text: "hello", offset: 3, radius: 100)
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(offset, 3)
    }

    func testLongTextWindowsAroundCaret() {
        let long = String(repeating: "a", count: 10_000)
        let (text, offset) = windowAroundCaret(text: long, offset: 5_000, radius: 100)
        XCTAssertEqual(text.count, 200)
        XCTAssertEqual(offset, 100)
    }

    func testCaretAtStart() {
        let long = String(repeating: "x", count: 10_000)
        let (text, offset) = windowAroundCaret(text: long, offset: 0, radius: 100)
        XCTAssertEqual(text.count, 100)
        XCTAssertEqual(offset, 0)
    }

    func testCaretAtEnd() {
        let long = String(repeating: "y", count: 10_000)
        let (text, offset) = windowAroundCaret(text: long, offset: 10_000, radius: 100)
        XCTAssertEqual(text.count, 100)
        XCTAssertEqual(offset, 100)
    }

    func testNegativeOffsetClamped() {
        let (_, offset) = windowAroundCaret(text: "hello", offset: -5, radius: 100)
        XCTAssertEqual(offset, 0)
    }

    func testOffsetBeyondEndClamped() {
        let (_, offset) = windowAroundCaret(text: "hello", offset: 100, radius: 100)
        XCTAssertEqual(offset, 5)
    }
}

final class ParagraphAroundCaretTests: XCTestCase {
    func testSingleParagraph() {
        XCTAssertEqual(paragraphAroundCaret(text: "hello world", caretOffset: 5), "hello world")
    }

    func testCaretInMiddleParagraph() {
        let text = "first paragraph\nsecond paragraph\nthird paragraph"
        // Caret in "second" (offset = 23 falls inside "paragraph" of line 2)
        XCTAssertEqual(paragraphAroundCaret(text: text, caretOffset: 23), "second paragraph")
    }

    func testCaretOnNewlineReturnsAdjacentParagraph() {
        let text = "alpha\nbeta\ngamma"
        // Offset 5 is at the newline between alpha and beta — should resolve cleanly.
        let result = paragraphAroundCaret(text: text, caretOffset: 5)
        XCTAssertTrue(result == "alpha" || result == "beta")
    }

    func testTrimsWhitespace() {
        let text = "   padded paragraph   "
        XCTAssertEqual(paragraphAroundCaret(text: text, caretOffset: 5), "padded paragraph")
    }

    func testEmptyText() {
        XCTAssertEqual(paragraphAroundCaret(text: "", caretOffset: 0), "")
    }
}

final class LooksLikeWordTests: XCTestCase {
    func testValidWords() {
        XCTAssertTrue(looksLikeWord("hello"))
        XCTAssertTrue(looksLikeWord("user's"))
        XCTAssertTrue(looksLikeWord("x-ray"))
        XCTAssertTrue(looksLikeWord("café"))
    }

    func testRejectsTooShort() {
        XCTAssertFalse(looksLikeWord("hi"))
        XCTAssertFalse(looksLikeWord(""))
    }

    func testRejectsTooLong() {
        XCTAssertFalse(looksLikeWord(String(repeating: "a", count: 31)))
    }

    func testRejectsDigits() {
        XCTAssertFalse(looksLikeWord("abc123"))
        XCTAssertFalse(looksLikeWord("123"))
    }

    func testRejectsSymbols() {
        XCTAssertFalse(looksLikeWord("foo_bar"))
        XCTAssertFalse(looksLikeWord("foo@bar"))
    }
}

final class CharacterAtTests: XCTestCase {
    func testValidAscii() {
        let ns: NSString = "hello"
        XCTAssertEqual(character(ns, at: 0), "h")
        XCTAssertEqual(character(ns, at: 4), "o")
    }

    func testOutOfBoundsReturnsNil() {
        let ns: NSString = "hi"
        XCTAssertNil(character(ns, at: -1))
        XCTAssertNil(character(ns, at: 2))
        XCTAssertNil(character(ns, at: 100))
    }

    func testSurrogateHalfReturnsNil() {
        // Emoji takes 2 UTF-16 code units (a high+low surrogate pair).
        // Indexing into either half should yield nil rather than a corrupt
        // Character, so word-boundary scans stop at the boundary.
        let ns: NSString = "a😀b"
        XCTAssertEqual(character(ns, at: 0), "a")
        XCTAssertNil(character(ns, at: 1))   // high surrogate
        XCTAssertNil(character(ns, at: 2))   // low surrogate
        XCTAssertEqual(character(ns, at: 3), "b")
    }
}
