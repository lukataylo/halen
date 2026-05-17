import XCTest
@testable import Halen

final class LogRedactTests: XCTestCase {
    /// The whole point of redaction is that the original text never appears
    /// in the output. A failure of this test means we shipped a regression
    /// that leaks user content into os_log.
    func testRedactDoesNotEchoContent() {
        let secret = "user-password-12345"
        let redacted = Log.redact(secret)
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertFalse(redacted.contains("password"))
        XCTAssertFalse(redacted.contains("12345"))
    }

    func testRedactIsDeterministic() {
        XCTAssertEqual(Log.redact("hello"), Log.redact("hello"))
    }

    func testRedactDistinguishesContent() {
        XCTAssertNotEqual(Log.redact("foo"), Log.redact("bar"))
    }

    func testRedactExposesLength() {
        XCTAssertTrue(Log.redact("12345").contains("len=5"))
        XCTAssertTrue(Log.redact("").contains("len=0"))
    }

    func testRedactFingerprintFormat() {
        // 8 hex chars from SHA-256, prefixed with #
        let r = Log.redact("anything")
        XCTAssertTrue(r.contains("#"))
        // <len=N #abcd1234> shape
        XCTAssertTrue(r.hasPrefix("<"))
        XCTAssertTrue(r.hasSuffix(">"))
    }
}
