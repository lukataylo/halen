import Foundation
import OSLog

enum Log {
    static let logger = Logger(subsystem: "com.dadiani.halen", category: "halen")

    /// Mirror every log line to a flat file at `/tmp/halen-trace.log` *in
    /// addition* to os_log. The unified log routinely drops or hides info-
    /// and debug-level messages from custom subsystems unless you `sudo log
    /// config --mode level:debug,persist:info`, which makes ad-hoc debugging
    /// painful. A file mirror is unconditional and easy to `tail -f`.
    /// Truncated to 1 MB-ish at startup so the file doesn't grow forever.
    private static let traceHandle: FileHandle? = {
        let path = "/tmp/halen-trace.log"
        let fm = FileManager.default
        // Soft-rotate: if the existing file is over 4 MB, roll it.
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64, size > 4 * 1024 * 1024 {
            try? fm.moveItem(atPath: path, toPath: path + ".old")
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        // `seekToEnd()` is marked `@discardableResult` upstream but the
        // strict toolchain on CI flagged the `try?` swallow as "result of
        // 'try?' is unused" (warnings-as-errors). Bind to `_` to silence it;
        // we genuinely don't care about the returned offset.
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private static let traceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Serial queue for file writes — multiple goroutines/actors can call
    /// `Log.info` concurrently; FileHandle is not thread-safe on its own.
    private static let traceQueue = DispatchQueue(label: "halen.log.trace")

    private static func appendTrace(_ level: String, _ message: String) {
        guard let handle = traceHandle else { return }
        let ts = traceFormatter.string(from: Date())
        let line = "\(ts) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        traceQueue.async { try? handle.write(contentsOf: data) }
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        appendTrace("info", message)
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        appendTrace("debug", message)
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        appendTrace("warn", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        appendTrace("error", message)
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
