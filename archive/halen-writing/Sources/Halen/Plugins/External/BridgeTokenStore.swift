import Foundation
import CryptoKit

/// Persisted authentication token for the local WebSocket bridge. Generated
/// once per user, written 0600 in `~/Library/Application Support/Halen/`,
/// and required from every WS client before it can receive events or inject
/// them onto the EventBus.
///
/// Why: loopback-only binding isn't a real trust boundary — any process
/// running as the user can `nc 127.0.0.1 50765`. The token gates connections
/// so only the apps the user has explicitly paired (the browser extension,
/// future iOS companion) can read or write through the bridge.
enum BridgeTokenStore {
    private static let filename = "bridge-token"

    private static var tokenURL: URL? {
        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir
            .appending(path: "Halen", directoryHint: .isDirectory)
            .appending(path: filename)
    }

    /// Read the token, generating + persisting one on first call. Idempotent.
    /// Returns `nil` only if the file system refuses to give us a usable
    /// Application Support directory — in which case the bridge effectively
    /// can't authenticate and refuses every client (fail-closed).
    static func tokenOrCreate() -> String? {
        guard let url = tokenURL else { return nil }
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        return generateAndWrite(to: url)
    }

    /// Rotate the token — revokes every existing client. The user calls this
    /// from Settings when they suspect the token leaked or want to reset
    /// extension pairing.
    @discardableResult
    static func regenerate() -> String? {
        guard let url = tokenURL else { return nil }
        return generateAndWrite(to: url)
    }

    private static func generateAndWrite(to url: URL) -> String? {
        // 32 bytes of CSPRNG → 64 hex chars. Long enough to make brute force
        // over a local socket pointless without being unwieldy to copy/paste.
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try token.write(to: url, atomically: true, encoding: .utf8)
            // 0600 — readable + writable by owner only. The whole point of
            // the token is that other users / processes can't lift it from
            // disk; default umask on macOS is 0644 which would defeat that.
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                 ofItemAtPath: url.path)
        } catch {
            Log.warn("BridgeTokenStore: failed to persist token — \(error.localizedDescription)")
            return nil
        }
        Log.info("BridgeTokenStore: generated new bridge token")
        return token
    }
}
