import XCTest
@testable import Halen

final class HashingTests: XCTestCase {
    func testKnownVectors() {
        // Standard test vectors for SHA-256 of UTF-8 input.
        XCTAssertEqual(
            sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testDeterministic() {
        let h1 = sha256Hex("the quick brown fox")
        let h2 = sha256Hex("the quick brown fox")
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64)
    }

    func testDifferentInputsDifferentHashes() {
        XCTAssertNotEqual(sha256Hex("foo"), sha256Hex("bar"))
    }
}
