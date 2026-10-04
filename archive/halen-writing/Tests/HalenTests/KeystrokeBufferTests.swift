import XCTest
@testable import Halen

/// Covers `parseKeystrokeTrigger` — the pure trigger-detection logic behind
/// snippet expansion in text boxes the Accessibility API can't read.
final class KeystrokeBufferTests: XCTestCase {

    func testSimpleTriggerWithSpace() {
        let match = parseKeystrokeTrigger(in: ";sig ", delimiter: " ")
        XCTAssertEqual(match?.token, ";sig")
        XCTAssertEqual(match?.preceding, "")
    }

    func testTriggerClosedByPunctuation() {
        let match = parseKeystrokeTrigger(in: ";today.", delimiter: ".")
        XCTAssertEqual(match?.token, ";today")
        XCTAssertEqual(match?.preceding, "")
    }

    func testTriggerKeepsPrecedingText() {
        let match = parseKeystrokeTrigger(in: "Hi there ;sig ", delimiter: " ")
        XCTAssertEqual(match?.token, ";sig")
        XCTAssertEqual(match?.preceding, "Hi there ")
    }

    func testDigitsAllowedInTrigger() {
        let match = parseKeystrokeTrigger(in: ";addr2 ", delimiter: " ")
        XCTAssertEqual(match?.token, ";addr2")
    }

    func testNoSentinelIsNotATrigger() {
        XCTAssertNil(parseKeystrokeTrigger(in: "hello ", delimiter: " "))
    }

    func testWordWithoutLeadingSemicolonIsNotATrigger() {
        // "email@" — the word "email" has no ";" immediately before it.
        XCTAssertNil(parseKeystrokeTrigger(in: "email ", delimiter: " "))
    }

    func testBareSemicolonIsNotATrigger() {
        // Typing just ";" then a delimiter — empty word, must not fire.
        XCTAssertNil(parseKeystrokeTrigger(in: "; ", delimiter: " "))
        XCTAssertNil(parseKeystrokeTrigger(in: ";;", delimiter: ";"))
    }

    func testDelimiterMustBeTheLastCharacter() {
        // The buffer's tail doesn't end with the claimed delimiter.
        XCTAssertNil(parseKeystrokeTrigger(in: ";sig x", delimiter: " "))
    }

    func testMidWordHasNotTriggeredYet() {
        // No delimiter typed yet — nothing should match.
        XCTAssertNil(parseKeystrokeTrigger(in: ";si", delimiter: " "))
    }

    func testSemicolonItselfAsDelimiter() {
        // ";sig;" — the second ";" closes the token.
        let match = parseKeystrokeTrigger(in: ";sig;", delimiter: ";")
        XCTAssertEqual(match?.token, ";sig")
        XCTAssertEqual(match?.preceding, "")
    }

    func testPrecedingParagraphForAISnippet() {
        let typed = "The meeting went well and we agreed on next steps. ;summary "
        let match = parseKeystrokeTrigger(in: typed, delimiter: " ")
        XCTAssertEqual(match?.token, ";summary")
        XCTAssertEqual(match?.preceding,
                       "The meeting went well and we agreed on next steps. ")
    }
}
