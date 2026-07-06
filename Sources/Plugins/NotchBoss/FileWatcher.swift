import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "file-watcher")

/// Watches locked files for external modifications.
/// If a locked file is modified by something other than the lock owner,
/// raises a conflict so the user can decide what to do.
class FileWatcher {
    private var timer: Timer?
    private var lastModDates: [String: Date] = [:]
    private let coordination: CoordinationEngine

    /// Recently written files (by tool-use events from known agents).
    /// When we see a modification on a locked file, we skip it if
    /// the lock owner just wrote to it (within this window).
    private var recentToolWrites: [String: Date] = [:]
    private let recentWriteWindow: TimeInterval = 5.0

    init(coordination: CoordinationEngine) {
        self.coordination = coordination
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                self?.checkLockedFiles()
            }
        }
        log.info("File watcher started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Record that a known agent just wrote to a file (suppresses false-positive conflicts).
    func recordAgentWrite(_ filePath: String) {
        let normalized = (filePath as NSString).standardizingPath
        recentToolWrites[normalized] = Date()
    }

    private func checkLockedFiles() {
        let locks = coordination.activeLocks

        // Clean up stale recent-write entries
        let now = Date()
        recentToolWrites = recentToolWrites.filter { now.timeIntervalSince($0.value) < recentWriteWindow }

        for (path, fileLock) in locks {
            guard !fileLock.isStale else { continue }

            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date else {
                continue
            }

            let lastKnown = lastModDates[path]
            lastModDates[path] = modDate

            // First time seeing this file — just record the date
            guard let last = lastKnown else { continue }

            // File was modified since last check
            if modDate > last {
                // Skip if the lock owner's agent just wrote to it
                if let recentWrite = recentToolWrites[path], now.timeIntervalSince(recentWrite) < recentWriteWindow {
                    continue
                }

                // This is an external modification — detect the modifier
                let modifier = identifyModifier()
                log.warning("External modification on locked file: \(path) by \(modifier) (owned by \(fileLock.agentType))")

                coordination.recordExternalConflict(
                    filePath: path,
                    modifierApp: modifier,
                    ownerLock: fileLock
                )
            }
        }

        // Clean up entries for files that are no longer locked
        let lockedPaths = Set(locks.keys)
        lastModDates = lastModDates.filter { lockedPaths.contains($0.key) }
    }

    /// Try to identify what app modified the file by checking the frontmost application.
    /// This is a heuristic — if the frontmost app is a known editor, it's likely the modifier.
    private func identifyModifier() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "Unknown" }
        let bundleID = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? "Unknown"

        // Map known bundle IDs to friendly names
        let knownApps: [String: String] = [
            "com.microsoft.VSCode": "VS Code",
            "com.todesktop.230313mzl4w4u92": "Cursor",
            "dev.warp.Warp-Stable": "Warp",
            "com.apple.Terminal": "Terminal",
            "com.googlecode.iterm2": "iTerm2",
            "com.sublimetext": "Sublime Text",
            "com.jetbrains": "JetBrains",
            "org.vim": "Vim",
            "com.apple.dt.Xcode": "Xcode",
        ]

        for (prefix, friendlyName) in knownApps {
            if bundleID.hasPrefix(prefix) { return friendlyName }
        }

        return name
    }
}
