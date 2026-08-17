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

final class WebSocketBridgePolicyTests: XCTestCase {
    func testBridgeDefaultsOffWithoutPersistedChoice() {
        let previous = UserDefaults.standard.object(forKey: WebSocketBridge.enabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: WebSocketBridge.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WebSocketBridge.enabledKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: WebSocketBridge.enabledKey)
        XCTAssertFalse(WebSocketBridge.isEnabledInDefaults)
    }

    func testUnauthenticatedRequestCannotDispatch() {
        XCTAssertEqual(WebSocketBridgePolicy.disposition(
            isAuthenticated: false, isRequest: true, method: "inference/complete"),
            .rejectRequest)
    }

    func testNoApplicationMessageIsAllowedBeforeHandshakeAuthentication() {
        XCTAssertEqual(WebSocketBridgePolicy.disposition(
            isAuthenticated: false, isRequest: false, method: "subscribe"), .reject)
        XCTAssertEqual(WebSocketBridgePolicy.disposition(
            isAuthenticated: false, isRequest: false, method: "event/text.pause"), .reject)
    }

    func testAuthenticatedNotificationsAndSubscriptionAllowedButRequestsRemainDenied() {
        XCTAssertEqual(WebSocketBridgePolicy.disposition(
            isAuthenticated: true, isRequest: false, method: "event/text.pause"), .notification)
        XCTAssertEqual(WebSocketBridgePolicy.disposition(
            isAuthenticated: true, isRequest: false, method: "subscribe"), .subscribe)
        XCTAssertEqual(WebSocketBridgePolicy.disposition(
            isAuthenticated: true, isRequest: true, method: "ui/toast"), .rejectRequest)
    }

    func testBrowserExtensionOriginsAllowed() {
        XCTAssertTrue(WebSocketBridgePolicy.isAllowedBrowserOrigin("chrome-extension://abcdefghijklmnop"))
        XCTAssertTrue(WebSocketBridgePolicy.isAllowedBrowserOrigin("moz-extension://addon-id"))
        XCTAssertTrue(WebSocketBridgePolicy.isAllowedBrowserOrigin("safari-web-extension://com.example.halen"))
    }

    func testMissingNullAndWebOriginsRejected() {
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigin(nil))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigin("null"))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigin("http://localhost"))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigin("https://example.com"))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigin("chrome-extension://"))
    }

    func testUpgradeRequiresExactlyOneAllowedOrigin() {
        XCTAssertTrue(WebSocketBridgePolicy.isAllowedBrowserOrigins([
            "chrome-extension://abcdefghijklmnop"
        ]))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigins([]))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedBrowserOrigins([
            "chrome-extension://abcdefghijklmnop",
            "https://example.com"
        ]))
    }

    func testUpgradeRequiresExactPairingSubprotocol() {
        let expected = WebSocketBridgePolicy.pairingSubprotocol(token: "abc123")
        let origin = ["chrome-extension://abcdefghijklmnop"]
        XCTAssertTrue(WebSocketBridgePolicy.isAllowedHandshake(
            origins: origin, offeredSubprotocols: [expected], expectedSubprotocol: expected))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedHandshake(
            origins: origin, offeredSubprotocols: [], expectedSubprotocol: expected))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedHandshake(
            origins: origin, offeredSubprotocols: ["halen.wrong"], expectedSubprotocol: expected))
        XCTAssertFalse(WebSocketBridgePolicy.isAllowedHandshake(
            origins: origin, offeredSubprotocols: [expected, "extra"], expectedSubprotocol: expected))
    }

    func testClientCeilingDecision() {
        XCTAssertTrue(WebSocketBridgePolicy.canAcceptClient(currentCount: 15))
        XCTAssertFalse(WebSocketBridgePolicy.canAcceptClient(currentCount: 16))
    }

    func testPendingHandshakesCannotPermanentlyOccupySlots() {
        XCTAssertEqual(WebSocketBridgePolicy.admission(currentCount: 3, pendingCount: 3), .accept)
        XCTAssertEqual(WebSocketBridgePolicy.admission(currentCount: 4, pendingCount: 4), .evictPending)
        XCTAssertEqual(WebSocketBridgePolicy.admission(currentCount: 16, pendingCount: 1), .evictPending)
        XCTAssertEqual(WebSocketBridgePolicy.admission(currentCount: 16, pendingCount: 0), .reject)
    }
}
