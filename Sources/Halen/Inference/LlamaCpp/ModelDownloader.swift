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
        request.timeoutInterval = 60
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        // Polite identity. HuggingFace serves unauthenticated requests, just
        // with tighter rate limits; not relevant for a single ~800 MB file.
        request.setValue("Halen-Mac/0.1", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60   // 1 h hard cap
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
            // ~64 KB write buffer — bigger reduces syscalls, smaller updates
            // the progress UI more often. 64 KB is a fine middle.
            var buffer = Data(capacity: 65_536)
            var lastReport = Date()

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > 0.1 {
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
            let actualHash = try sha256Hash(of: partPath)
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

    /// Streaming SHA-256 — never loads the full 770 MB into memory.
    private func sha256Hash(of fileURL: URL) throws -> String {
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
