import Foundation
import CryptoKit

/// Hex-encoded SHA-256 of `text`'s UTF-8 bytes. Used by tone-style plugins to
/// fingerprint a paragraph for cache dedup — same paragraph, same hash, no
/// repeat Gemma round-trip.
func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
