import Foundation
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "coordination")

// MARK: - File Lock

struct FileLock: Codable {
    let filePath: String
    let agentType: String      // "claude", "codex", "cursor", etc.
    let sessionName: String
    let sessionId: String
    let claimedAt: Date

    /// Locks expire after this many seconds to prevent stale locks from dead sessions.
    static let expirySeconds: TimeInterval = 300

    var isStale: Bool {
        Date().timeIntervalSince(claimedAt) > Self.expirySeconds
    }
}

// MARK: - Conflict

struct FileConflict: Identifiable {
    let id = UUID()
    let filePath: String
    let ownerAgent: String
    let ownerSession: String
    let blockedAgent: String
    let blockedSession: String
    let isExternal: Bool   // True if detected via file watcher, false if via hook
    let detectedAt: Date = Date()

    var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    var shortPath: String {
        let parts = filePath.split(separator: "/")
        return parts.count > 2 ? String(parts.suffix(2).joined(separator: "/")) : filePath
    }

    var age: String {
        let seconds = Date().timeIntervalSince(detectedAt)
        if seconds < 60 { return "<1m" }
        return "\(Int(seconds / 60))m"
    }
}

// MARK: - Conflict Stats

struct ConflictStats {
    var conflictsPrevented: Int = 0
    var filesCoordinated: Int = 0
    var activeLocksCount: Int = 0
}

// MARK: - Coordination Engine

/// Manages file locks across all active agent sessions to prevent concurrent edits.
/// When two agents try to edit the same file, the second one is blocked and notified.
class CoordinationEngine: ObservableObject {
    static let shared = CoordinationEngine()

    @Published var activeLocks: [String: FileLock] = [:]  // keyed by normalized file path
    @Published var activeConflicts: [FileConflict] = []
    @Published var stats = ConflictStats()

    private let lock = NSLock()
    private let stateDir: URL

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notchbar")
        stateDir = base.appendingPathComponent("coordination")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        loadState()
    }

    // MARK: - File Locking

    /// Claim a file for an agent. Returns nil if successful, or the existing lock if conflict.
    func claimFile(_ filePath: String, agentType: String, sessionName: String, sessionId: String) -> FileLock? {
        let normalized = normalizePath(filePath)

        lock.lock()
        defer { lock.unlock() }

        // Check for existing lock
        if let existing = activeLocks[normalized] {
            // Same session reclaiming its own lock is fine
            if existing.sessionId == sessionId { return nil }
            // Stale lock — take it over
            if existing.isStale {
                log.info("Overriding stale lock on \(normalized) from \(existing.agentType)")
            } else {
                // Conflict!
                log.warning("Conflict: \(agentType)/\(sessionName) blocked on \(normalized) — owned by \(existing.agentType)/\(existing.sessionName)")
                return existing
            }
        }

        let newLock = FileLock(
            filePath: normalized,
            agentType: agentType,
            sessionName: sessionName,
            sessionId: sessionId,
            claimedAt: Date()
        )
        activeLocks[normalized] = newLock
        stats.filesCoordinated += 1
        saveState()
        return nil
    }

    /// Release a file lock.
    func releaseFile(_ filePath: String, sessionId: String) {
        let normalized = normalizePath(filePath)
        lock.lock()
        defer { lock.unlock() }

        if let existing = activeLocks[normalized], existing.sessionId == sessionId {
            activeLocks.removeValue(forKey: normalized)
            saveState()
        }
    }

    /// Release all locks held by a session (e.g., when session ends).
    func releaseAllForSession(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }

        let keysToRemove = activeLocks.filter { $0.value.sessionId == sessionId }.map(\.key)
        for key in keysToRemove {
            activeLocks.removeValue(forKey: key)
        }
        if !keysToRemove.isEmpty {
            log.info("Released \(keysToRemove.count) locks for session \(sessionId)")
            saveState()
        }
    }

    // MARK: - Conflict Detection

    /// Evaluate a tool-use event. Returns a blocking conflict if the file is locked by another agent.
    /// Automatically claims the file if it's not locked.
    func evaluateToolUse(
        toolName: String,
        filePath: String?,
        agentType: String,
        sessionName: String,
        sessionId: String
    ) -> FileConflict? {
        // Only check write operations
        guard isWriteTool(toolName), let path = filePath else { return nil }

        if let existingLock = claimFile(path, agentType: agentType, sessionName: sessionName, sessionId: sessionId) {
            let conflict = FileConflict(
                filePath: path,
                ownerAgent: existingLock.agentType,
                ownerSession: existingLock.sessionName,
                blockedAgent: agentType,
                blockedSession: sessionName,
                isExternal: false
            )

            DispatchQueue.main.async { [weak self] in
                self?.activeConflicts.append(conflict)
                self?.stats.conflictsPrevented += 1
            }

            return conflict
        }

        return nil
    }

    /// Record an external modification conflict (from FileWatcher).
    func recordExternalConflict(filePath: String, modifierApp: String, ownerLock: FileLock) {
        let conflict = FileConflict(
            filePath: filePath,
            ownerAgent: ownerLock.agentType,
            ownerSession: ownerLock.sessionName,
            blockedAgent: modifierApp,
            blockedSession: modifierApp,
            isExternal: true
        )

        DispatchQueue.main.async { [weak self] in
            // Don't duplicate for the same file
            self?.activeConflicts.removeAll { $0.filePath == filePath }
            self?.activeConflicts.append(conflict)
            self?.stats.conflictsPrevented += 1
        }
    }

    /// Resolve a conflict (user chose to keep owner or let modifier in).
    func resolveConflict(_ conflict: FileConflict, keepOwner: Bool) {
        if !keepOwner {
            // Transfer the lock to the blocked agent
            lock.lock()
            activeLocks.removeValue(forKey: normalizePath(conflict.filePath))
            lock.unlock()
            saveState()
        }

        DispatchQueue.main.async { [weak self] in
            self?.activeConflicts.removeAll { $0.id == conflict.id }
        }

        log.info("Resolved conflict on \(conflict.fileName): \(keepOwner ? "kept owner" : "let modifier in")")
    }

    /// Dismiss all conflicts older than a threshold.
    func expireOldConflicts(maxAge: TimeInterval = 30) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        DispatchQueue.main.async { [weak self] in
            self?.activeConflicts.removeAll { $0.detectedAt < cutoff }
        }
    }

    /// Remove stale locks from dead sessions.
    func expireStaleLocks() {
        lock.lock()
        let staleKeys = activeLocks.filter { $0.value.isStale }.map(\.key)
        for key in staleKeys {
            activeLocks.removeValue(forKey: key)
        }
        let lockCount = activeLocks.count
        lock.unlock()

        if !staleKeys.isEmpty {
            log.info("Expired \(staleKeys.count) stale locks")
            saveState()
        }

        DispatchQueue.main.async { [weak self] in
            self?.stats.activeLocksCount = lockCount
        }
    }

    // MARK: - Helpers

    private func isWriteTool(_ toolName: String) -> Bool {
        ["Edit", "Write", "Bash", "NotebookEdit", "apply_patch", "exec_command"].contains(toolName)
    }

    private func normalizePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    // MARK: - Persistence

    private var stateFile: URL { stateDir.appendingPathComponent("file_locks.json") }

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(activeLocks.values)) else { return }
        try? data.write(to: stateFile)
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let locks = try? decoder.decode([FileLock].self, from: data) else { return }
        for l in locks where !l.isStale {
            activeLocks[normalizePath(l.filePath)] = l
        }
        stats.activeLocksCount = activeLocks.count
        let loadedCount = activeLocks.count
        log.info("Loaded \(loadedCount) file locks from disk")
    }

    /// Get lock info for a file, if any.
    func lockInfo(for filePath: String) -> FileLock? {
        lock.lock()
        defer { lock.unlock() }
        return activeLocks[normalizePath(filePath)]
    }
}
