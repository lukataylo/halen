import Foundation
import OSLog
import Darwin

enum Log {
    static let logger = Logger(subsystem: "com.dadiani.halen", category: "halen")

    /// Mirror every log line to a flat file *in addition* to os_log. The
    /// unified log routinely drops or hides info- and debug-level messages
    /// from custom subsystems unless you `sudo log config --mode
    /// level:debug,persist:info`, which makes ad-hoc debugging painful. A
    /// file mirror is unconditional and easy to `tail -f`.
    ///
    /// Path: `~/Library/Application Support/Halen/halen-trace.log` —
    /// per-user, persists across reboots, no permission collision on
    /// multi-user Macs. If Application Support cannot be secured, file
    /// mirroring is disabled; sensitive logs must never fall back to /tmp.
    ///
    /// Path resolution is inlined here (not via `HalenSupportDirectory`)
    /// to avoid a static-init cycle: `HalenSupportDirectory.root` calls
    /// `Log.error` on failure, and that would re-enter this initializer
    /// on first failed access.
    private static let maxTraceBytes: off_t = 4 * 1024 * 1024

    private static let traceHandle: FileHandle? = {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first else { return nil }
        return openSecureTraceFile(in: support.appending(path: "Halen"))
    }()

    /// Creates/opens the trace file without following a final-component
    /// symlink. Internal for focused filesystem security tests.
    static func openSecureTraceFile(in directory: URL) -> FileHandle? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }

        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return nil }
        defer { close(directoryFD) }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR,
              directoryStat.st_uid == geteuid() else { return nil }
        guard fchmod(directoryFD, 0o700) == 0 else { return nil }

        let fd = openat(directoryFD, "halen-trace.log",
                        O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                        0o600)
        guard fd >= 0 else { return nil }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == geteuid(),
              fchmod(fd, 0o600) == 0 else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Keep one bounded file rather than racing a predictable `.old` path.
    /// All production calls run on traceQueue; internal for focused tests.
    static func writeBounded(_ data: Data, to handle: FileHandle,
                             maxBytes: off_t = maxTraceBytes) throws {
        guard maxBytes > 0 else { return }
        let fd = handle.fileDescriptor
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == geteuid() else { return }
        if fileStat.st_size > maxBytes || off_t(data.count) > maxBytes - fileStat.st_size {
            guard ftruncate(fd, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        // A single oversized record cannot be allowed to defeat the bound.
        let bounded = data.count > Int(maxBytes) ? data.suffix(Int(maxBytes)) : data[...]
        try handle.write(contentsOf: Data(bounded))
    }

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
        traceQueue.async {
            let ts = traceFormatter.string(from: Date())
            let line = "\(ts) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? writeBounded(data, to: handle)
        }
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

    static func redactedToastDescription(title: String, body: String) -> String {
        "toast: title=\(redact(title)) body=\(redact(body))"
    }

    static func redactedPluginStderrDescription(pluginID: String, line: String) -> String {
        "plugin[\(pluginID)] stderr=\(redact(line))"
    }
}
