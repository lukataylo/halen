import XCTest
@testable import Halen

final class PluginManifestIDValidationTests: XCTestCase {
    func testValidIDs() {
        XCTAssertTrue(PluginManifest.isValidID("com.acme.snippets"))
        XCTAssertTrue(PluginManifest.isValidID("snippets"))
        XCTAssertTrue(PluginManifest.isValidID("plugin-1"))
        XCTAssertTrue(PluginManifest.isValidID("a"))
    }

    func testRejectsEmpty() {
        XCTAssertFalse(PluginManifest.isValidID(""))
    }

    func testRejectsPathSeparators() {
        XCTAssertFalse(PluginManifest.isValidID("foo/bar"))
        XCTAssertFalse(PluginManifest.isValidID("foo\\bar"))
        XCTAssertFalse(PluginManifest.isValidID("/abs"))
    }

    func testRejectsWhitespace() {
        XCTAssertFalse(PluginManifest.isValidID("foo bar"))
        XCTAssertFalse(PluginManifest.isValidID("foo\tbar"))
        XCTAssertFalse(PluginManifest.isValidID("foo\nbar"))
    }

    func testRejectsDoubleDot() {
        XCTAssertFalse(PluginManifest.isValidID(".."))
        XCTAssertFalse(PluginManifest.isValidID("com..foo"))
        XCTAssertFalse(PluginManifest.isValidID(".."))
    }

    func testRejectsSingleDotOnly() {
        XCTAssertFalse(PluginManifest.isValidID("."))
    }

    func testRejectsOverlyLong() {
        XCTAssertFalse(PluginManifest.isValidID(String(repeating: "a", count: 129)))
        XCTAssertTrue(PluginManifest.isValidID(String(repeating: "a", count: 128)))
    }
}

final class PluginManifestPathContainmentTests: XCTestCase {
    func testCandidateInsidePluginDirIsAllowed() {
        let base = URL(fileURLWithPath: "/tmp/halen/plugins/foo")
        let candidate = base.appending(path: "bin/run")
        XCTAssertTrue(PluginManifest.isExecutablePathContained(candidate, in: base))
    }

    func testCandidateOutsidePluginDirIsRejected() {
        let base = URL(fileURLWithPath: "/tmp/halen/plugins/foo")
        let traversal = base.appending(path: "../../../../etc/passwd")
        XCTAssertFalse(PluginManifest.isExecutablePathContained(traversal, in: base))
    }

    func testCandidateAtBaseIsAllowed() {
        let base = URL(fileURLWithPath: "/tmp/halen/plugins/foo")
        XCTAssertTrue(PluginManifest.isExecutablePathContained(base, in: base))
    }

    func testSiblingDirectoryIsRejected() {
        let base = URL(fileURLWithPath: "/tmp/halen/plugins/foo")
        let sibling = URL(fileURLWithPath: "/tmp/halen/plugins/foobar/bin")
        // "foobar" starts with "foo" lexically — without the trailing-slash
        // anchor in `isExecutablePathContained`, a sibling whose name is a
        // prefix of the base would slip through. Pin the regression.
        XCTAssertFalse(PluginManifest.isExecutablePathContained(sibling, in: base))
    }
}

final class PluginManifestValidateTests: XCTestCase {
    /// End-to-end: a manifest whose relative `executable` traverses out of
    /// the plugin dir is rejected by `validate(at:)`.
    func testValidateRejectsPathTraversal() throws {
        let tmp = try makeTempPluginDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = PluginManifest(
            id: "com.test.evil",
            name: "Evil",
            summary: nil,
            version: "1.0",
            halenApiVersion: "0.1",
            executable: "../../../../bin/sh",   // path traversal
            args: nil, env: nil, events: nil,
            permissions: nil, icon: nil, category: nil,
            claudeCodePluginDir: nil
        )

        XCTAssertThrowsError(try manifest.validate(at: tmp)) { err in
            guard case ManifestError.executableOutsidePluginDir = err else {
                XCTFail("Expected .executableOutsidePluginDir, got \(err)")
                return
            }
        }
    }

    func testValidateRejectsInvalidID() throws {
        let tmp = try makeTempPluginDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = PluginManifest(
            id: "../etc/passwd",
            name: "Bad",
            summary: nil,
            version: "1.0",
            halenApiVersion: "0.1",
            executable: "run.sh",
            args: nil, env: nil, events: nil,
            permissions: nil, icon: nil, category: nil,
            claudeCodePluginDir: nil
        )

        XCTAssertThrowsError(try manifest.validate(at: tmp)) { err in
            guard case ManifestError.invalidID = err else {
                XCTFail("Expected .invalidID, got \(err)")
                return
            }
        }
    }

    func testValidateRejectsUnsupportedApiVersion() throws {
        let tmp = try makeTempPluginDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = PluginManifest(
            id: "com.test.future",
            name: "Future", summary: nil, version: "1.0",
            halenApiVersion: "9.99",
            executable: "run.sh",
            args: nil, env: nil, events: nil,
            permissions: nil, icon: nil, category: nil,
            claudeCodePluginDir: nil
        )

        XCTAssertThrowsError(try manifest.validate(at: tmp)) { err in
            guard case ManifestError.unsupportedApiVersion = err else {
                XCTFail("Expected .unsupportedApiVersion, got \(err)")
                return
            }
        }
    }

    func testValidateAcceptsRelativePathStayingInside() throws {
        let tmp = try makeTempPluginDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create an executable file inside the plugin dir.
        let binDir = tmp.appending(path: "bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let exec = binDir.appending(path: "run.sh")
        try "#!/bin/sh\necho ok".write(to: exec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: exec.path
        )

        let manifest = PluginManifest(
            id: "com.test.good",
            name: "Good", summary: nil, version: "1.0",
            halenApiVersion: "0.1",
            executable: "bin/run.sh",
            args: nil, env: nil, events: nil,
            permissions: nil, icon: nil, category: nil,
            claudeCodePluginDir: nil
        )

        XCTAssertNoThrow(try manifest.validate(at: tmp))
    }

    private func makeTempPluginDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "halen-plugin-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
