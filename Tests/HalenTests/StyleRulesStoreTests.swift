import XCTest
@testable import Halen

/// Locks in the word-boundary semantics of `StyleRulesStore.wordRange`. The
/// risk this guards against: banning "form" and accidentally flagging
/// "format", or banning "use" and flagging "user". Loud failures here keep
/// the rule scanner trustworthy when a user pastes in their own banned-word
/// list.
@MainActor
final class StyleRulesStoreTests: XCTestCase {

    func testRespectsWordBoundary_doesNotMatchInsideLongerWord() {
        XCTAssertNil(range(of: "form", in: "We need to format the response."))
        XCTAssertNil(range(of: "use", in: "The user clicked save."))
        XCTAssertNil(range(of: "very unique", in: "discoveryunique"))
    }

    func testCaseInsensitiveStandaloneMatch() {
        XCTAssertEqual(range(of: "form", in: "Fill out the form please."),
                       NSRange(location: 13, length: 4))
        XCTAssertEqual(range(of: "form", in: "Form follows function."),
                       NSRange(location: 0, length: 4))
    }

    func testPunctuationCountsAsBoundary() {
        XCTAssertEqual(range(of: "form", in: "Submit the form."),
                       NSRange(location: 11, length: 4))
        XCTAssertEqual(range(of: "form", in: "(form)"),
                       NSRange(location: 1, length: 4))
    }

    func testMultiWordPhraseMatches() {
        XCTAssertEqual(range(of: "very unique", in: "This is very unique stuff."),
                       NSRange(location: 8, length: 11))
    }

    // MARK: helpers

    private func range(of term: String, in text: String) -> NSRange? {
        StyleRulesStore.wordRange(of: term, in: text as NSString)
    }
}
