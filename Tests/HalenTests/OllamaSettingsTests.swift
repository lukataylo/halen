import XCTest
@testable import Halen

final class OllamaSettingsValidationTests: XCTestCase {
    func testValidatesCanonicalDefault() {
        XCTAssertNotNil(OllamaSettings.validate("http://localhost:11434"))
        XCTAssertNotNil(OllamaSettings.validate("http://127.0.0.1:11434"))
        XCTAssertNotNil(OllamaSettings.validate("https://ollama.local:11434"))
    }

    func testTrimsWhitespace() {
        let parsed = OllamaSettings.validate("  http://localhost:11434  ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.host, "localhost")
        XCTAssertEqual(parsed?.port, 11434)
    }

    func testRejectsEmpty() {
        XCTAssertNil(OllamaSettings.validate(""))
        XCTAssertNil(OllamaSettings.validate("   "))
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertNil(OllamaSettings.validate("ftp://localhost:11434"))
        XCTAssertNil(OllamaSettings.validate("file:///tmp/ollama.sock"))
        XCTAssertNil(OllamaSettings.validate("ws://localhost:11434"))
    }

    func testRejectsSchemelessOrMalformed() {
        XCTAssertNil(OllamaSettings.validate("localhost:11434"))   // no scheme → URL has no host
        XCTAssertNil(OllamaSettings.validate("http://"))            // no host
        XCTAssertNil(OllamaSettings.validate(":11434"))
    }

    func testAcceptsCustomPort() {
        let parsed = OllamaSettings.validate("http://localhost:11435")
        XCTAssertEqual(parsed?.port, 11435)
    }

    func testAcceptsHTTPS() {
        XCTAssertEqual(OllamaSettings.validate("https://ollama.example.com")?.scheme, "https")
    }
}

final class OllamaSettingsLoopbackTests: XCTestCase {
    func testLocalhost() {
        XCTAssertTrue(OllamaSettings.isLoopback(URL(string: "http://localhost:11434")!))
    }

    func testIPv4Loopback() {
        // 127.0.0.0/8 — every 127.x.x.x is loopback.
        XCTAssertTrue(OllamaSettings.isLoopback(URL(string: "http://127.0.0.1:11434")!))
        XCTAssertTrue(OllamaSettings.isLoopback(URL(string: "http://127.0.0.2:11434")!))
        XCTAssertTrue(OllamaSettings.isLoopback(URL(string: "http://127.42.42.42:11434")!))
    }

    func testIPv6Loopback() {
        XCTAssertTrue(OllamaSettings.isLoopback(URL(string: "http://[::1]:11434")!))
    }

    func testRemoteHostNotLoopback() {
        XCTAssertFalse(OllamaSettings.isLoopback(URL(string: "http://192.168.1.10:11434")!))
        XCTAssertFalse(OllamaSettings.isLoopback(URL(string: "http://ollama.example.com")!))
        XCTAssertFalse(OllamaSettings.isLoopback(URL(string: "http://10.0.0.1:11434")!))
    }

    func testHostnameStartingWith127NotIP() {
        // Edge case: a hostname like "127.thingy.local" lexically starts
        // with "127." but isn't a 127/8 IP (it's a DNS name whose first
        // label happens to be "127"). With a pure-prefix match this is
        // accepted as loopback; the test documents the known
        // false-positive so a future tightening (numeric-octet parsing)
        // can flip this expectation deliberately.
        XCTAssertTrue(OllamaSettings.isLoopback(URL(string: "http://127.thingy.local:11434")!))
    }
}

/// Round-trip the settings through UserDefaults to pin the contract the
/// OllamaBackend depends on: stored → currentBaseURL → default fallback.
/// `UserDefaults.standard` is global, so each test saves and restores the
/// key in a defer block instead of using a suite — the production code path
/// reads the standard defaults, and we want the tests to exercise that exact
/// path rather than an isolated mock.
final class OllamaSettingsPersistenceTests: XCTestCase {
    private func withClearedStoredValue(_ body: () -> Void) {
        let key = OllamaSettings.baseURLKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    private func withStoredValue(_ raw: String, _ body: () -> Void) {
        let key = OllamaSettings.baseURLKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(raw, forKey: key)
        body()
    }

    func testDefaultConstants() {
        XCTAssertEqual(OllamaSettings.defaultBaseURLString, "http://localhost:11434")
        XCTAssertEqual(OllamaSettings.defaultBaseURL.host, "localhost")
        XCTAssertEqual(OllamaSettings.defaultBaseURL.port, 11434)
    }

    func testCurrentFallsBackToDefaultWhenUnset() {
        withClearedStoredValue {
            XCTAssertEqual(OllamaSettings.currentBaseURL(), OllamaSettings.defaultBaseURL)
        }
    }

    func testCurrentRoundtripsValidStoredValue() {
        withStoredValue("http://127.0.0.1:11500") {
            let url = OllamaSettings.currentBaseURL()
            XCTAssertEqual(url.host, "127.0.0.1")
            XCTAssertEqual(url.port, 11500)
        }
    }

    func testCurrentFallsBackOnGarbageStoredValue() {
        withStoredValue("not a url") {
            XCTAssertEqual(OllamaSettings.currentBaseURL(), OllamaSettings.defaultBaseURL)
        }
    }

    func testCurrentFallsBackOnEmptyStoredValue() {
        withStoredValue("") {
            XCTAssertEqual(OllamaSettings.currentBaseURL(), OllamaSettings.defaultBaseURL)
        }
    }
}
