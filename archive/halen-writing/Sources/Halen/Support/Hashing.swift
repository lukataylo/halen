import Foundation
import CryptoKit

/// Hex-encoded SHA-256 of `text`'s UTF-8 bytes. Used by tone-style plugins to
/// fingerprint a paragraph for cache dedup — same paragraph, same hash, no
/// repeat Gemma round-trip.
///
/// Implementation note: this lives on the per-paragraph hot path adjacent to
/// classifier inference (called once per settle from `ParagraphClassifier`),
/// so the encode is done inline into a single 64-byte buffer. The earlier
/// `.map { String(format: "%02x", $0) }.joined()` form allocated 65 strings
/// per call (32 two-char fragments + the join buffer plus format-string
/// overhead); this version allocates exactly one `String` and never touches
/// `String(format:)`.
func sha256Hex(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    // Lookup table: byte → two lowercase hex ASCII chars. Keeping it as a
    // `[UInt8]` (not a `String`) means each lookup is a single byte read.
    let hexChars: [UInt8] = Array("0123456789abcdef".utf8)
    return String(unsafeUninitializedCapacity: 64) { buffer in
        var offset = 0
        for byte in digest {
            buffer[offset]     = hexChars[Int(byte >> 4)]
            buffer[offset + 1] = hexChars[Int(byte & 0x0F)]
            offset += 2
        }
        return 64
    }
}
