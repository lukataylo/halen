import Foundation
import CryptoKit
import Observation

/// Downloads the bundled Gemma 4 E4B GGUF on demand from the canonical
/// HuggingFace mirror into `ModelLocation.downloaded`. ~4.98 GB, so the
/// download is resumable (HTTP Range requests), verified by SHA-256
/// against a pinned hash, atomically installed (.part staging file is moved
/// into place only after the hash matches).
///
/// `@Observable` so SwiftUI can drive a download UI off `state` without an
/// explicit Combine pipeline.
@MainActor
@Observable
final class ModelDownloader {
    /// Canonical download URL — the `unsloth/gemma-4-E4B-it-GGUF` mirror.
    /// Unsloth's Q4_K_M packs ~400 MB smaller than bartowski's for the same
    /// nominal quant. No auth token required; supports HTTP Range;
    /// HuggingFace 302s to a CloudFront/xet signed URL which `URLSession`
    /// follows automatically.
    static let sourceURL = URL(string:
        "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf"
    )!

    /// Expected file size in bytes. Used for the progress denominator before
    /// the body even starts streaming, and as a fast sanity check before the
    /// SHA-256 verification.
    static let expectedSize: Int64 = 4_977_169_568   // ~4.98 GB

    /// Pinned content hash from HuggingFace's `x-linked-etag`. If this ever
    /// fails to match, the upstream file changed — bump the hash here and
    /// the user is forced to re-download.
    static let expectedSHA256 =
        "519b9793ed6ce0ff530f1b7c96e848e08e49e7af4d57bb97f76215963a54146d"

    // MARK: - Tunables

    /// Bytes flushed to disk per write. Larger ⇒ fewer syscalls, smaller ⇒
    /// finer-grained progress updates. 64 KiB is the empirical sweet spot.
    private static let writeBufferBytes = 64 * 1024
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

    init() {
        // On launch we trust the existence of the file; the (multi-second)
        // SHA-256 check only runs when the user explicitly triggers a verify
        // or after a fresh download.
        self.state = ModelLocation.isAvailable ? .ready : .notDownloaded
    }

    /// Start (or resume) the download. Idempotent — calling while a download
    /// is already in flight is a no-op.
    func start() {
        if downloadTask != nil { return }
        guard let installPath = ModelLocation.downloaded else {
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
        if let path = ModelLocation.downloaded {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: path.appendingPathExtension("part"))
        }
        state = ModelLocation.isAvailable ? .ready : .notDownloaded
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
            fraction: Double(resumeOffset) / Double(Self.expectedSize),
            bytes: resumeOffset,
            total: Self.expectedSize
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
            // refuses to let cross actor boundaries).
            weak let weakSelf = self
            let inner = Task.detached(priority: .utility) {
                try await Self.performDownload(
                    sourceURL: Self.sourceURL,
                    partPath: partPath,
                    resumeOffset: resumeOffset,
                    expectedSize: Self.expectedSize,
                    requestTimeout: Self.requestTimeout,
                    resourceTimeout: Self.resourceTimeout,
                    writeBufferBytes: Self.writeBufferBytes,
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
        } catch {
            state = .failed(message: error.localizedDescription)
            return
        }

        // Size sanity-check before the (~3 s) full SHA-256 pass — catches
        // truncated transfers cheaply.
        if written != Self.expectedSize {
            state = .failed(message:
                "Downloaded \(written) bytes, expected \(Self.expectedSize). Try again.")
            return
        }

        do {

            state = .verifying
            try Task.checkCancellation()
            // SHA-256 on 770 MB is ~3 s. Off-main so the "Verifying…" state in
            // Settings stays responsive — the main thread was previously stuck
            // for the duration, locking the menu UI and any other plugin work.
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
            guard actualHash == Self.expectedSHA256 else {
                // Hash mismatch is almost always a corrupt mirror or
                // bit-flipped transfer — wipe the .part so the next attempt
                // starts fresh, never serve a wrong file to llama.cpp.
                try? fm.removeItem(at: partPath)
                state = .failed(message: "Downloaded file failed integrity check. Try again.")
                return
            }

            state = .installing
            // Atomic move into place. If something already lives at `finalPath`
            // (e.g. a previous broken download), replace it.
            if fm.fileExists(atPath: finalPath.path) {
                try fm.removeItem(at: finalPath)
            }
            try fm.moveItem(at: partPath, to: finalPath)

            Log.info("ModelDownloader: installed \(finalPath.path) (\(written) bytes)")
            state = .ready

        } catch is CancellationError {
            state = .notDownloaded
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Pumps the URLSession byte stream into the `.part` file on a background
    /// task. Everything it touches is either a value type, a Sendable
    /// reference (URL, URLSession created here), or the locally-owned
    /// FileHandle — nothing crosses back to the MainActor except via the
    /// `onProgress` callback, which marshals its own hop.
    ///
    /// Throws `CancellationError` when the parent task is cancelled (the
    /// `try Task.checkCancellation()` inside the loop is the propagation
    /// point), `DownloadError.badStatus(_)` on a non-200/206 response, and
    /// `DownloadError.noHTTPResponse` when the URL loading system hands us
    /// back something that isn't an `HTTPURLResponse`.
    nonisolated private static func performDownload(
        sourceURL: URL,
        partPath: URL,
        resumeOffset: Int64,
        expectedSize: Int64,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        writeBufferBytes: Int,
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
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.noHTTPResponse
        }
        // 206 on resume, 200 on a fresh download (or when the server ignored
        // our Range — treat as fresh and rewrite the part file).
        let startingFresh = http.statusCode == 200
        if !startingFresh && http.statusCode != 206 {
            throw DownloadError.badStatus(http.statusCode)
        }

        let fm = FileManager.default
        if startingFresh || !fm.fileExists(atPath: partPath.path) {
            fm.createFile(atPath: partPath.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partPath)
        if startingFresh {
            try handle.truncate(atOffset: 0)
        } else {
            try handle.seekToEnd()
        }
        defer { try? handle.close() }

        var written: Int64 = startingFresh ? 0 : resumeOffset
        var buffer = Data(capacity: writeBufferBytes)
        var lastReport = Date()

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= writeBufferBytes {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > progressInterval {
                    onProgress(Double(written) / Double(expectedSize), written, expectedSize)
                    lastReport = Date()
                }
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()
        return written
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
enum DownloadError: Error {
    case noHTTPResponse
    case badStatus(Int)
}
