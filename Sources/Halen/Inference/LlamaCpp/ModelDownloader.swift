import Foundation
import CryptoKit
import Observation

/// Downloads the bundled-Gemma GGUF on demand from the canonical HuggingFace
/// mirror into `ModelLocation.downloaded`. Resumable (HTTP Range requests),
/// verified by SHA-256 against a pinned hash, atomically installed (.part
/// staging file is moved into place only after the hash matches).
///
/// `@Observable` so SwiftUI can drive a download UI off `state` without an
/// explicit Combine pipeline.
@MainActor
@Observable
final class ModelDownloader {
    /// Canonical download URL — the `ggml-org/gemma-3-1b-it-GGUF` mirror,
    /// confirmed byte-identical to the previously-bundled file. No auth token
    /// required; supports HTTP Range; HuggingFace 302s to a CloudFront/xet
    /// signed URL which `URLSession` follows automatically.
    static let sourceURL = URL(string:
        "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf"
    )!

    /// Expected file size in bytes. Used for the progress denominator before
    /// the body even starts streaming, and as a fast sanity check before the
    /// (~3 s) SHA-256 verification.
    static let expectedSize: Int64 = 806_058_240

    /// Pinned content hash. Cross-verified against the existing bundled file
    /// and HuggingFace's `x-linked-etag`. If this ever fails to match, the
    /// upstream file changed — bump the hash here and the user is forced to
    /// re-download.
    static let expectedSHA256 =
        "8ccc5cd1f1b3602548715ae25a66ed73fd5dc68a210412eea643eb20eb75a135"

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
    private var session: URLSession?

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
    /// next `start()` resumes from where it stopped.
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
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

        var request = URLRequest(url: Self.sourceURL)
        request.timeoutInterval = Self.requestTimeout
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        // Polite identity. HuggingFace serves unauthenticated requests, just
        // with tighter rate limits; not relevant for a single ~800 MB file.
        request.setValue("Halen-Mac/0.1", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = Self.resourceTimeout
        let session = URLSession(configuration: config)
        self.session = session
        defer { self.session = nil }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed(message: "Unexpected response from server")
                return
            }
            // 206 on resume, 200 on a fresh download (or when the server
            // ignored our Range — treat as fresh and rewrite the part file).
            let startingFresh = http.statusCode == 200
            if !startingFresh && http.statusCode != 206 {
                state = .failed(message: "Server returned HTTP \(http.statusCode)")
                return
            }

            // Open the .part file: truncate on a fresh response, append on resume.
            if startingFresh {
                fm.createFile(atPath: partPath.path, contents: nil)
            } else if !fm.fileExists(atPath: partPath.path) {
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
            var buffer = Data(capacity: Self.writeBufferBytes)
            var lastReport = Date()

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.writeBufferBytes {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > Self.progressReportInterval {
                        state = .downloading(
                            fraction: Double(written) / Double(Self.expectedSize),
                            bytes: written,
                            total: Self.expectedSize
                        )
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

            // Size sanity-check before the (~3 s) full SHA-256 pass — catches
            // truncated transfers cheaply.
            if written != Self.expectedSize {
                state = .failed(message:
                    "Downloaded \(written) bytes, expected \(Self.expectedSize). Try again.")
                return
            }

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

    /// Streaming SHA-256 — never loads the full 770 MB into memory. Marked
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
