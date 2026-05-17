import Foundation
import OSLog

enum Log {
    static let logger = Logger(subsystem: "com.dadiani.halen", category: "halen")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Non-reversible short fingerprint of user-supplied text for log lines
    /// that need to correlate two events (e.g. TypoFixer learning a word and
    /// later applying it) without writing the user's actual content to disk.
    /// The privacy posture is: anything the user typed is treated as PII; if
    /// a log line previously contained substrings of `payload.text`, the
    /// preview, an AI response, or a learned typo word, it now contains
    /// `<len=N #abcd1234>` instead. Reversing requires brute force of every
    /// plausible string of length N against SHA-256 — practically impossible
    /// for any non-trivial content.
    static func redact(_ text: String) -> String {
        let hash = sha256Hex(text).prefix(8)
        return "<len=\(text.count) #\(hash)>"
    }
}
