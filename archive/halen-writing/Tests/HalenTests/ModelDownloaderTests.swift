import XCTest
@testable import Halen

/// The Content-Range parser is the security boundary between trusting an
/// HTTP 206 response (server claims it's resuming our partial transfer at
/// the right offset) and overwriting good bytes with garbage. Every edge
/// case it gets wrong is a silent file-corruption opportunity.
final class ContentRangeParserTests: XCTestCase {
    func testCanonicalForm() {
        let parsed = ModelDownloader.parseContentRange("bytes 1024-4977169567/4977169568")
        XCTAssertEqual(parsed?.start, 1024)
        XCTAssertEqual(parsed?.end, 4_977_169_567)
        XCTAssertEqual(parsed?.total, 4_977_169_568)
    }

    func testUnknownTotal() {
        let parsed = ModelDownloader.parseContentRange("bytes 0-99/*")
        XCTAssertEqual(parsed?.start, 0)
        XCTAssertEqual(parsed?.end, 99)
        XCTAssertNil(parsed?.total)
    }

    func testLeadingWhitespaceTolerated() {
        let parsed = ModelDownloader.parseContentRange("  bytes 0-9/10  ")
        XCTAssertEqual(parsed?.start, 0)
        XCTAssertEqual(parsed?.end, 9)
        XCTAssertEqual(parsed?.total, 10)
    }

    func testRejectsMissingPrefix() {
        XCTAssertNil(ModelDownloader.parseContentRange("1024-2047/4096"))
    }

    func testRejectsMissingTotal() {
        XCTAssertNil(ModelDownloader.parseContentRange("bytes 1024-2047"))
    }

    func testRejectsMissingDash() {
        XCTAssertNil(ModelDownloader.parseContentRange("bytes 10242047/4096"))
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(ModelDownloader.parseContentRange("bytes abc-def/ghi"))
        XCTAssertNil(ModelDownloader.parseContentRange("bytes 0-99/abc"))
    }

    func testRejectsNegativeOrInverted() {
        XCTAssertNil(ModelDownloader.parseContentRange("bytes -1-99/100"))
        XCTAssertNil(ModelDownloader.parseContentRange("bytes 99-1/100"))   // end < start
    }

    func testRejectsMultipart() {
        // We deliberately don't try to interpret multipart/byteranges responses —
        // we don't request them and they have no business arriving.
        XCTAssertNil(ModelDownloader.parseContentRange("multipart/byteranges; boundary=xyz"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(ModelDownloader.parseContentRange(""))
        XCTAssertNil(ModelDownloader.parseContentRange("bytes "))
        XCTAssertNil(ModelDownloader.parseContentRange("bytes /"))
    }

    func testZeroLengthRangeAllowed() {
        // Single-byte resume from offset 0 — `0-0/1` is canonically valid.
        let parsed = ModelDownloader.parseContentRange("bytes 0-0/1")
        XCTAssertEqual(parsed?.start, 0)
        XCTAssertEqual(parsed?.end, 0)
        XCTAssertEqual(parsed?.total, 1)
    }
}
