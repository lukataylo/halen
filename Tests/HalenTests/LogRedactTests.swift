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

    func testSecureTraceFileUsesPrivateModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try XCTUnwrap(Log.openSecureTraceFile(in: root))
        defer { try? handle.close() }
        let dirMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.appending(path: "halen-trace.log").path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(dirMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testSecureTraceFileRejectsSymlinkAndNonRegularFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let trace = root.appending(path: "halen-trace.log")
        try fm.createSymbolicLink(at: trace, withDestinationURL: root.appending(path: "target"))
        XCTAssertNil(Log.openSecureTraceFile(in: root))
        try fm.removeItem(at: trace)
        try fm.createDirectory(at: trace, withIntermediateDirectories: false)
        XCTAssertNil(Log.openSecureTraceFile(in: root))
    }

    func testBoundedWriteTruncatesWithoutRotation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let handle = try XCTUnwrap(Log.openSecureTraceFile(in: root))
        defer { try? handle.close() }
        try Log.writeBounded(Data(repeating: 0x41, count: 12), to: handle, maxBytes: 16)
        try Log.writeBounded(Data(repeating: 0x42, count: 8), to: handle, maxBytes: 16)
        let content = try Data(contentsOf: root.appending(path: "halen-trace.log"))
        XCTAssertEqual(content, Data(repeating: 0x42, count: 8))
        XCTAssertFalse(fm.fileExists(atPath: root.appending(path: "halen-trace.log.old").path))
    }

    func testSensitiveCallSiteDescriptionsRedactPayloads() {
        let toast = Log.redactedToastDescription(title: "private title", body: "private body")
        XCTAssertFalse(toast.contains("private title"))
        XCTAssertFalse(toast.contains("private body"))
        let stderr = Log.redactedPluginStderrDescription(pluginID: "example", line: "secret stderr")
        XCTAssertTrue(stderr.contains("plugin[example]"))
        XCTAssertFalse(stderr.contains("secret stderr"))
    }
}
