import Foundation
import CryptoKit
import Observation

/// Downloads a `ModelSpec`'s GGUF on demand from its pinned HuggingFace
/// mirror into `ModelLocation.downloaded(for: spec)`. Resumable (HTTP Range
/// requests), verified by SHA-256 against the spec's pinned hash, atomically
/// installed (the `.part` staging file is moved into place only after the
/// hash matches).
///
/// One `ModelDownloader` instance per `ModelSpec` — the host creates one for
/// Gemma (generation) and one for Qwen (classifier), each with its own
/// SwiftUI-observable `state`.
///
/// `@Observable` so SwiftUI can drive a download UI off `state` without an
/// explicit Combine pipeline.
@MainActor
@Observable
final class ModelDownloader {
    /// The model this downloader manages. Frozen at init — one downloader
    /// per model spec.
    let spec: ModelSpec

    /// Convenient access to spec fields used by call sites that don't want to
    /// drill through `.spec.*`.
    var expectedSize: Int64 { spec.expectedSize }
    var displayName: String { spec.displayName }

    // MARK: - Tunables

    /// Minimum interval between `state = .downloading(…)` updates. Keeps the
    /// SwiftUI progress card smooth without flooding the MainActor.
    private static let progressReportInterval: TimeInterval = 0.1
    /// HTTP request-line timeout. Matches the `URLSessionConfiguration` default
    /// for outbound TCP setup; resource timeout below is much larger.
    private static let requestTimeout: TimeInterval = 60
    /// Hard ceiling for the entire transfer. 1 hour covers an 800 MB download
    /// on even a slow residential link — beyond that we'd rather fail loudly.
    private static let resourceTimeout: TimeInterval = 60 * 60

    enum State: Equatable {
        case notDownloaded
        case downloading(fraction: Double, bytes: Int64, total: Int64)
        case verifying
        case installing
        case ready
        case failed(message: String)
    }

    private(set) var state: State

    private var downloadTask: Task<Void, Never>?

    init(spec: ModelSpec) {
        self.spec = spec
        // On launch we trust the existence of the file; the (multi-second)
        // SHA-256 check only runs when the user explicitly triggers a verify
        // or after a fresh download.
        self.state = ModelLocation.isAvailable(for: spec) ? .ready : .notDownloaded
    }

    /// Start (or resume) the download. Idempotent — calling while a download
    /// is already in flight is a no-op.
    func start() {
        if downloadTask != nil { return }
        guard let installPath = ModelLocation.downloaded(for: spec) else {
            state = .failed(message: "Couldn't resolve Application Support directory")
            return
        }
        downloadTask = Task { [weak self] in
            await self?.run(installingTo: installPath)
            await MainActor.run { self?.downloadTask = nil }
        }
    }

    /// Abort an in-flight download. Leaves the `.part` file in place so the
    /// next `start()` resumes from where it stopped. The cancellation flows
    /// through `withTaskCancellationHandler` in `run(...)` into the detached
    /// download body, which winds down on its next `Task.checkCancellation()`.
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state {
            state = .notDownloaded
        }
    }

    /// Remove the downloaded model file. The bundled fallback (if any) stays.
    func removeDownloaded() {
        cancel()
        if let path = ModelLocation.downloaded(for: spec) {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: path.appendingPathExtension("part"))
        }
        state = ModelLocation.isAvailable(for: spec) ? .ready : .notDownloaded
    }

    // MARK: - Implementation

    private func run(installingTo finalPath: URL) async {
        let partPath = finalPath.appendingPathExtension("part")
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: finalPath.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            state = .failed(message: "Couldn't create Models directory: \(error.localizedDescription)")
            return
        }

        // Resume offset: how many bytes of `.part` we already have.
        let resumeOffset: Int64 = (try? fm.attributesOfItem(atPath: partPath.path)[.size] as? Int64) ?? 0

        // Initial state — start the progress UI even before the first byte.
        state = .downloading(
            fraction: Double(resumeOffset) / Double(spec.expectedSize),
            bytes: resumeOffset,
            total: spec.expectedSize
        )

        // Hand off the actual byte-pumping to a detached Task so the iter-
        // bytes loop doesn't run on the MainActor. `performDownload(...)` is
        // nonisolated static and takes everything it needs by value, so no
        // MainActor state escapes the detached context. Progress updates
        // come back through the `onProgress` closure, which hops via
        // `Task { @MainActor in }` so SwiftUI sees the state changes on
        // its expected actor.
        //
        // `withTaskCancellationHandler` wires the OUTER `downloadTask`'s
        // cancellation through to the detached child — without that bridge
        // the user pressing Cancel would unblock the await but leave the
        // download running silently in the background for up to an hour.
        let written: Int64
        do {
            // Re-bind `self` to a local `weak` so the progress callback
            // captures a Sendable weak ref, not the `var self` of the
            // surrounding closure (which the strict-concurrency checker
            // refuses to let cross actor boundaries). Snapshot the spec
            // fields the detached body needs into locals for the same reason.
            //
            // `weak var` (not `let`) — Swift 5.10 rejects `weak let`:
            // "'weak' must be a mutable variable, because it may change
            // at runtime". The runtime mutates the storage to nil when
            // the pointee dies, so the binding has to be mutable. Swift
            // 6 accepts `weak let` but CI runs on 5.10 (Xcode 15.4) and
            // is the source of truth.
            weak var weakSelf = self
            let sourceURL = spec.sourceURL
            let expectedSize = spec.expectedSize
            let inner = Task.detached(priority: .utility) {
                try await Self.performDownload(
                    sourceURL: sourceURL,
                    partPath: partPath,
                    resumeOffset: resumeOffset,
                    expectedSize: expectedSize,
                    requestTimeout: Self.requestTimeout,
                    resourceTimeout: Self.resourceTimeout,
                    progressInterval: Self.progressReportInterval,
                    onProgress: { fraction, bytes, total in
                        Task { @MainActor in
                            weakSelf?.state = .downloading(
                                fraction: fraction, bytes: bytes, total: total
                            )
                        }
                    }
                )
            }
            written = try await withTaskCancellationHandler {
                try await inner.value
            } onCancel: {
                inner.cancel()
            }
        } catch is CancellationError {
            state = .notDownloaded
            return
        } catch let DownloadError.badStatus(code) {
            state = .failed(message: "Server returned HTTP \(code)")
            return
        } catch DownloadError.noHTTPResponse {
            state = .failed(message: "Unexpected response from server")
            return
        } catch let DownloadError.unexpectedSize(claimed, expected) {
            // Server is offering a file of the wrong size. Don't overwrite —
            // wipe the staging file so a future retry can't silently resume
            // into a half-and-half corrupt state.
            try? fm.removeItem(at: partPath)
            state = .failed(message:
                "Server is offering a \(claimed)-byte file but Halen expects \(expected). The mirror may be wrong — try again later.")
            return
        } catch let DownloadError.badContentRange(reason) {
            // Bad Range response — drop the .part and start fresh next time;
            // resuming after a bogus range header would corrupt the file.
            try? fm.removeItem(at: partPath)
            state = .failed(message: "Couldn't resume the download (\(reason)). Try again to restart from scratch.")
            return
        } catch let DownloadError.exceededExpectedSize(written, expected) {
            try? fm.removeItem(at: partPath)
            state = .failed(message:
                "Server over-served the download (\(written) > \(expected) bytes). Refusing to fill disk; try again later.")
            return
        } catch {
            state = .failed(message: error.localizedDescription)
            return
        }

        // Size sanity-check before the (~3 s) full SHA-256 pass — catches
        // truncated transfers cheaply.
        if written != spec.expectedSize {
            state = .failed(message:
                "Downloaded \(written) bytes, expected \(spec.expectedSize). Try again.")
            return
        }

        do {

            state = .verifying
            try Task.checkCancellation()
            // SHA-256 on a multi-GB GGUF is multi-second. Off-main so the
            // "Verifying…" state in Settings stays responsive — the main thread
            // was previously stuck for the duration, locking the menu UI and
            // any other plugin work.
            let hashPath = partPath
            let actualHash: String
            do {
                actualHash = try await Task.detached(priority: .userInitiated) {
                    try Self.sha256Hash(of: hashPath)
                }.value
            } catch {
                try? fm.removeItem(at: partPath)
                state = .failed(message: "Couldn't verify downloaded file: \(error.localizedDescription)")
                return
            }
            // A `nil` pin in the spec skips verification — only valid for dev
            // specs. Production specs always carry the pinned x-linked-etag.
            if let pinned = spec.expectedSHA256 {
                guard actualHash == pinned else {
                    // Hash mismatch is almost always a corrupt mirror or a
                    // bit-flipped transfer — wipe the .part so the next attempt
                    // starts fresh, never serve a wrong file to llama.cpp.
                    try? fm.removeItem(at: partPath)
                    state = .failed(message: "Downloaded file failed integrity check. Try again.")
                    return
                }
            } else {
                Log.warn("ModelDownloader[\(spec.id)]: no SHA-256 pin — skipping integrity check (dev only)")
            }

            state = .installing
            // Atomic move into place. If something already lives at `finalPath`
            // (e.g. a previous broken download), replace it.
            if fm.fileExists(atPath: finalPath.path) {
                try fm.removeItem(at: finalPath)
            }
            try fm.moveItem(at: partPath, to: finalPath)

            Log.info("ModelDownloader[\(spec.id)]: installed \(finalPath.path) (\(written) bytes)")
            state = .ready

        } catch is CancellationError {
            state = .notDownloaded
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Streams the model body into the `.part` file via a delegate-driven
    /// `URLSessionDataTask` — the OS delivers the body in network-sized `Data`
    /// chunks, which the delegate writes straight to disk.
    ///
    /// Replaced an earlier `URLSession.bytes(for:)` loop that iterated the
    /// ~5 GB body one `UInt8` at a time: billions of async-sequence steps,
    /// each doing a single-byte `Data.append` and a `Task.checkCancellation()`
    /// — that turned an I/O-bound download into a CPU-bound one.
    ///
    /// Throws `CancellationError` when the parent task is cancelled (the
    /// `withTaskCancellationHandler` cancels the URLSession task, which the
    /// delegate maps from `NSURLErrorCancelled`), `DownloadError.badStatus(_)`
    /// on a non-200/206 response, `DownloadError.noHTTPResponse` for a
    /// non-HTTP response, and the framing errors from `ChunkedDownloadDelegate`.
    nonisolated private static func performDownload(
        sourceURL: URL,
        partPath: URL,
        resumeOffset: Int64,
        expectedSize: Int64,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        progressInterval: TimeInterval,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws -> Int64 {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = requestTimeout
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        // Polite identity. HuggingFace serves unauthenticated requests with
        // tighter rate limits — not relevant for a single multi-GB download.
        request.setValue("Halen-Mac/0.1", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = resourceTimeout

        let delegate = ChunkedDownloadDelegate(
            partPath: partPath,
            expectedSize: expectedSize,
            resumeOffset: resumeOffset,
            progressInterval: progressInterval,
            onProgress: onProgress
        )
        // The session retains its delegate until invalidated; `invalidateAndCancel`
        // in the defer releases it and tears down any in-flight task.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            task.resume()
            // `delegate.result()` resolves from `didCompleteWithError`, which
            // fires for every resumed task — success, failure, or cancel — so
            // the continuation can't leak.
            return try await delegate.result()
        } onCancel: {
            task.cancel()
        }
    }

    /// Parse `Content-Range: bytes <start>-<end>/<total|*>`. Returns the
    /// numeric start, end, and total (or nil for `*`). Returns nil if the
    /// header doesn't match the canonical bytes-range form.
    /// `nonisolated static` so tests (and any future caller) can invoke it
    /// from any context — the function is pure.
    nonisolated static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64?)? {
        // Canonical shape per RFC 7233: "bytes 1024-4977169567/4977169568"
        // or "bytes 1024-4977169567/*". Anything else (multipart, "bytes */N"
        // satisfiable-range responses, malformed) is rejected — we don't use
        // it, so we don't try to interpret it.
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst("bytes ".count)
        // `omittingEmptySubsequences: false` is critical here. Without it,
        // a leading-`-` value like "bytes -1-99/100" would split into
        // ["1", "99"] (the leading empty discarded) and silently parse as
        // start=1, end=99 — accepting a header we should reject.
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangePart = parts[0]
        let totalPart = parts[1]

        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0, end >= start
        else { return nil }

        let total: Int64?
        if totalPart == "*" {
            total = nil
        } else if let parsed = Int64(totalPart), parsed >= 0 {
            total = parsed
        } else {
            return nil
        }
        return (start, end, total)
    }

    /// Streaming SHA-256 — never loads the full GGUF into memory. Marked
    /// `nonisolated static` so it can be invoked from `Task.detached` without
    /// hopping back to the MainActor; capturing only the file path + the
    /// `Data` chunks it reads keeps the call genuinely off-main.
    nonisolated private static func sha256Hash(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.availableData
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Errors thrown by the detached download body that `run(installingTo:)`
/// translates into user-facing `.failed(message:)` states. Distinct from
/// `URLError` etc. so the outer dispatch knows which message is appropriate.
enum DownloadError: Error, Equatable {
    case noHTTPResponse
    case badStatus(Int)
    /// HTTP 200 + Content-Length didn't match `expectedSize`. The server is
    /// serving a different file than we pinned — refuse rather than overwrite.
    case unexpectedSize(claimed: Int64, expected: Int64)
    /// HTTP 206 but Content-Range either absent, malformed, or describing a
    /// different resume offset / total than we requested. Refuse rather than
    /// seekToEnd and silently corrupt the .part file.
    case badContentRange(String)
    /// Bytes streamed past `expectedSize` — server is over-serving (broken
    /// mirror or active MITM). Bail before the disk fills.
    case exceededExpectedSize(written: Int64, expected: Int64)
}

/// `URLSessionDataTask` delegate that streams the model body into the `.part`
/// file in network-sized `Data` chunks. The framing validation (status code,
/// `Content-Length` / `Content-Range`) runs in `didReceive response` and can
/// veto the download with `.cancel` before a single byte is written.
///
/// Concurrency: a URLSession delivers all callbacks for one task serially on
/// its (here non-main) delegate queue. With one task per session that serial
/// guarantee is the synchronisation for the mutable state below — hence
/// `@unchecked Sendable` with no extra locking.
private final class ChunkedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partPath: URL
    private let expectedSize: Int64
    private let resumeOffset: Int64
    private let progressInterval: TimeInterval
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void

    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReport = Date()
    /// First fatal condition hit in a callback. Surfaced to the awaiting
    /// caller from `didCompleteWithError`; once set, later `didReceive data`
    /// callbacks are ignored.
    private var failure: Error?
    private var continuation: CheckedContinuation<Int64, Error>?

    init(partPath: URL, expectedSize: Int64, resumeOffset: Int64,
         progressInterval: TimeInterval,
         onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.partPath = partPath
        self.expectedSize = expectedSize
        self.resumeOffset = resumeOffset
        self.progressInterval = progressInterval
        self.onProgress = onProgress
    }

    /// Suspends until the task finishes. The continuation is resumed exactly
    /// once, from `didCompleteWithError` (which fires for every resumed task).
    func result() async throws -> Int64 {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try openFile(for: response)
            completionHandler(.allow)
        } catch {
            // Record the reason and cancel — `didCompleteWithError` fires next
            // and surfaces `failure` to the caller.
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            // Streaming overflow guard. The Content-Length / Content-Range
            // checks bound what we *agreed* to receive; this catches a server
            // (or MITM) that lied and is now writing past `expectedSize` —
            // bail before it fills the user's disk.
            if written > expectedSize {
                throw DownloadError.exceededExpectedSize(written: written, expected: expectedSize)
            }
            if Date().timeIntervalSince(lastReport) > progressInterval {
                onProgress(Double(written) / Double(expectedSize), written, expectedSize)
                lastReport = Date()
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let cont = continuation
        continuation = nil
        if let failure {
            cont?.resume(throwing: failure)
        } else if let error {
            // URLSession reports cancellation as `NSURLErrorCancelled`; map it
            // to Swift's `CancellationError` so the router and UI treat a
            // cancelled download the same as any other cancelled task.
            if (error as NSError).code == NSURLErrorCancelled {
                cont?.resume(throwing: CancellationError())
            } else {
                cont?.resume(throwing: error)
            }
        } else {
            cont?.resume(returning: written)
        }
    }

    // MARK: - File setup

    /// Validate the server's status + framing, then open the `.part` file at
    /// the correct offset. Throws on any mismatch — the disposition handler
    /// turns the throw into a `.cancel` so nothing is ever written.
    ///
    ///   - Fresh download (200): `Content-Length`, if present, must match the
    ///     pinned `expectedSize` — a different size means a different file.
    ///   - Resume (206): `Content-Range` must say the server is resuming from
    ///     exactly `resumeOffset` for a file of total `expectedSize`. A 206
    ///     that secretly seeks from zero would, after `seekToEnd()`, append
    ///     fresh bytes past our partial — corruption SHA-256 only catches
    ///     after the whole multi-GB transfer completes.
    private func openFile(for response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.noHTTPResponse
        }
        // 206 on resume, 200 on a fresh download (or when the server ignored
        // our Range — treat as fresh and rewrite the part file).
        let startingFresh = http.statusCode == 200
        if !startingFresh && http.statusCode != 206 {
            throw DownloadError.badStatus(http.statusCode)
        }

        if startingFresh {
            if let claimed = http.value(forHTTPHeaderField: "Content-Length"),
               let claimedSize = Int64(claimed),
               claimedSize != expectedSize {
                throw DownloadError.unexpectedSize(claimed: claimedSize, expected: expectedSize)
            }
        } else {
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = ModelDownloader.parseContentRange(range)
            else {
                throw DownloadError.badContentRange("missing or unparseable Content-Range")
            }
            if parsed.start != resumeOffset {
                throw DownloadError.badContentRange("server resumed from \(parsed.start), expected \(resumeOffset)")
            }
            if let total = parsed.total, total != expectedSize {
                throw DownloadError.badContentRange("server reports total \(total), expected \(expectedSize)")
            }
        }

        let fm = FileManager.default
        if startingFresh || !fm.fileExists(atPath: partPath.path) {
            fm.createFile(atPath: partPath.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: partPath)
        if startingFresh {
            try h.truncate(atOffset: 0)
        } else {
            try h.seekToEnd()
        }
        handle = h
        written = startingFresh ? 0 : resumeOffset
    }
}
