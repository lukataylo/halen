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

final class ModelSpecIntegrityTests: XCTestCase {
    func testDownloadURLsUseImmutableRevisions() {
        let specs = [ModelSpec.gemma4E4B_IQ4_XS, ModelSpec.qwen25_05B_Q4_K_M]

        for spec in specs {
            XCTAssertNotNil(spec.sourceURL.path.range(
                of: #"/resolve/[0-9a-f]{40}/"#,
                options: .regularExpression
            ), "\(spec.displayName) must download from an immutable commit")
            XCTAssertNotNil(spec.expectedSHA256)
            XCTAssertTrue(spec.expectedSize > 0)
        }
    }

    func testGemmaPinMatchesKnownArtifact() {
        let spec = ModelSpec.gemma4E4B_IQ4_XS

        XCTAssertTrue(spec.sourceURL.path.contains(
            "/resolve/653803f092503c04a65164346f3208a36e707693/"
        ))
        XCTAssertEqual(spec.expectedSize, 4_715_414_688)
        XCTAssertEqual(spec.expectedSHA256,
                       "eb29c8519c4c07b880fb9cae7ff13ee2e30c5f38516268920ab85c04df6d52a2")
    }

    func testQwenPinMatchesKnownArtifact() {
        let spec = ModelSpec.qwen25_05B_Q4_K_M

        XCTAssertTrue(spec.sourceURL.path.contains(
            "/resolve/9217f5db79a29953eb74d5343926648285ec7e67/"
        ))
        XCTAssertEqual(spec.expectedSize, 491_400_032)
        XCTAssertEqual(spec.expectedSHA256,
                       "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")
    }
}
