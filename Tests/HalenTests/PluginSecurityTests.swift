import XCTest
import CryptoKit
import SwiftUI
@testable import Halen

final class PluginRegistryAuthenticationTests: XCTestCase {
    func testCheckedInRegistryMatchesCompiledAuthenticationPin() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(path: "plugin-registry.json"))
        let index = try PluginRegistryIndex.decodeAuthenticated(data)
        XCTAssertTrue(index.plugins.isEmpty,
                      "Unavailable archives must not be advertised with placeholder hashes")
    }

    func testAuthenticatedV2DecodesAndTamperFails() throws {
        let data = Data(#"{"schemaVersion":2,"plugins":[]}"#.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try PluginRegistryIndex.decodeAuthenticated(data, expectedSHA256: digest))

        var tampered = data
        tampered.append(0x20)
        XCTAssertThrowsError(try PluginRegistryIndex.decodeAuthenticated(tampered,
                                                                         expectedSHA256: digest)) {
            XCTAssertEqual($0 as? RegistryError, .authenticationFailed)
        }
    }

    func testAuthenticatedV1IsRejected() throws {
        let data = Data(#"{"schemaVersion":1,"plugins":[]}"#.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try PluginRegistryIndex.decodeAuthenticated(data,
                                                                         expectedSHA256: digest)) {
            XCTAssertEqual($0 as? RegistryError, .unsupportedSchema(1))
        }
    }

    func testUnknownManifestPermissionIsRejected() {
        let json = #"{"id":"com.test.p","name":"P","version":"1","halenApiVersion":"0.1","executable":"run","events":[],"permissions":["filesystem.all"]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8)))
    }

    func testUnknownEventSubscriptionIsRejected() {
        let json = #"{"id":"com.test.p","name":"P","version":"1","halenApiVersion":"0.1","executable":"run","events":["secret.stream"],"permissions":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8)))
    }
}

final class PluginArchiveVerificationTests: XCTestCase {
    func testArchiveIndexRejectsBombTraversalAndSpecialEntries() throws {
        XCTAssertNoThrow(try PluginInstaller.validateArchiveIndex(
            summary: "2 files, 20 bytes uncompressed, 10 bytes compressed: 50%",
            listing: "-rw-r--r-- file.txt\ndrwxr-xr-x folder/",
            names: "file.txt\nfolder/"))
        XCTAssertThrowsError(try PluginInstaller.validateArchiveIndex(
            summary: "1 file, 101 bytes uncompressed, 10 bytes compressed: 90%",
            listing: "-rw-r--r-- huge", names: "huge", maxFiles: 10, maxBytes: 100))
        XCTAssertThrowsError(try PluginInstaller.validateArchiveIndex(
            summary: "1 file, 1 bytes uncompressed, 1 bytes compressed: 0%",
            listing: "-rw-r--r-- ../escape", names: "../escape"))
        XCTAssertThrowsError(try PluginInstaller.validateArchiveIndex(
            summary: "1 file, 1 bytes uncompressed, 1 bytes compressed: 0%",
            listing: "lrwxr-xr-x link", names: "link"))
    }

    func testArchiveHashAndSizeMustBothMatch() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("archive".utf8)
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        XCTAssertNoThrow(try PluginInstaller.verifyArchive(file, entry: entry(size: 7, hash: digest)))
        XCTAssertThrowsError(try PluginInstaller.verifyArchive(file, entry: entry(size: 8, hash: digest)))
        XCTAssertThrowsError(try PluginInstaller.verifyArchive(file,
            entry: entry(size: 7, hash: String(repeating: "0", count: 64))))
    }

    func testRemovalURLAlwaysUsesCanonicalRootAndValidatedID() throws {
        let root = URL(fileURLWithPath: "/tmp/Halen/Plugins")
        XCTAssertEqual(try PluginInstaller.removalURL(for: "com.test.p", installRoot: root),
                       root.appending(path: "com.test.p", directoryHint: .isDirectory))
        XCTAssertThrowsError(try PluginInstaller.removalURL(for: "../escape", installRoot: root))
    }

    private func entry(size: Int64, hash: String) -> PluginRegistryEntry {
        PluginRegistryEntry(id: "com.test.p", name: "P", summary: "P", author: "T",
                            version: "1", icon: nil, category: nil,
                            sourceURL: "https://example.com/source",
                            downloadURL: "https://example.com/p.zip",
                            archiveSHA256: hash, archiveSize: size,
                            permissions: [], events: [], isExample: nil)
    }
}

@MainActor
final class PluginPermissionMappingTests: XCTestCase {
    func testEveryHostMethodMapsToClosedPermission() {
        let expected: [String: PluginPermission] = [
            "inference/complete": .inference,
            "ax/readSelection": .axRead,
            "ax/replaceRange": .axWrite,
            "ui/toast": .notifications,
            "ui/prompt": .uiPrompt,
            "calendar/upcomingEvents": .calendar,
            "calendar/createEvent": .calendar,
            "profile/getToneProfile": .profilesRead,
            "profile/listToneProfiles": .profilesRead,
            "profile/setToneProfile": .profilesWrite,
        ]
        for (method, permission) in expected {
            XCTAssertEqual(HostBridge.requiredPermission(for: method), permission)
            XCTAssertFalse(HostBridge.isAuthorized(method: method, grantedPermissions: []))
            XCTAssertTrue(HostBridge.isAuthorized(method: method,
                                                   grantedPermissions: [permission.rawValue]))
        }
        XCTAssertNil(HostBridge.requiredPermission(for: "unknown"))
    }
}

final class PluginManifestHardeningTests: XCTestCase {
    func testAbsoluteExecutableRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try manifest(executable: "/bin/sh").validate(at: dir)) {
            guard case ManifestError.absoluteExecutable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testSymlinkExecutableRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "real")
        try "#!/bin/sh\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "run"),
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try manifest(executable: "run").validate(at: dir))
    }

    private func manifest(executable: String) -> PluginManifest {
        PluginManifest(id: "com.test.p", name: "P", summary: nil, version: "1",
                       halenApiVersion: "0.1", executable: executable, args: nil, env: nil,
                       events: [], permissions: [], icon: nil, category: nil)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@MainActor
final class ExternalPluginDefaultStateTests: XCTestCase {
    private final class StubPlugin: HalenPlugin {
        let id: String
        var name = "Stub"; var summary = "Stub"; var icon = "puzzlepiece"
        var category: PluginCategory = .productivity
        var starts = 0
        init(id: String) { self.id = id }
        func start() { starts += 1 }
        func stop() {}
    }

    func testExternalRegistrationDefaultsDisabled() {
        let id = "com.test.\(UUID().uuidString)"
        let defaultsKey = "plugin.\(id).enabled"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let plugin = StubPlugin(id: id)
        let registry = PluginRegistry()
        registry.register(plugin, defaultEnabled: false)
        XCTAssertFalse(registry.isEnabled(id))
        XCTAssertEqual(plugin.starts, 0)
        registry.toggle(id)
        XCTAssertEqual(plugin.starts, 1)
    }
}
