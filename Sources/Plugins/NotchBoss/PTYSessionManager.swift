import Foundation
import AppKit
import SwiftTerm
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "pty")

/// Manages PTY-based terminal sessions for embedded Claude Code.
/// Each session gets a LocalProcessTerminalView that handles PTY + terminal emulation.
class PTYSessionManager {
    static let shared = PTYSessionManager()

    private var terminalViews: [UUID: LocalProcessTerminalView] = [:]
    private var sessionPIDs: [UUID: pid_t] = [:]
    private var exitHandlers: [UUID: ProcessExitHandler] = [:]
    private let lock = NSLock()

    // MARK: - Claude Binary Discovery

    /// Find the claude binary on the system by checking common locations and PATH.
    func findClaudeBinary() -> String? {
        // Check common install locations first
        let candidates = [
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                log.info("Found claude at \(path)")
                return path
            }
        }

        // Fall back to `which claude` via the user's login shell
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let result = Shell.run(loginShell, ["-l", "-c", "which claude"]) {
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                log.info("Found claude via which: \(path)")
                return path
            }
        }

        log.warning("Could not find claude binary")
        return nil
    }

    /// Resolve the user's login shell PATH so child processes inherit it.
    func resolveLoginPATH() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let result = Shell.run(shell, ["-l", "-c", "echo $PATH"]) {
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    }

    // MARK: - Session Lifecycle

    /// Create a new terminal session, spawning claude in the given directory.
    /// Returns the terminal view and session UUID, or nil if claude binary not found.
    func createSession(
        sessionId: UUID,
        cwd: String,
        args: [String] = [],
        onProcessExit: @escaping (UUID, Int32) -> Void
    ) -> LocalProcessTerminalView? {
        guard let claudePath = findClaudeBinary() else {
            log.error("Cannot create session: claude binary not found")
            return nil
        }

        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        // Configure terminal appearance
        terminalView.configureNativeColors()
        let termFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.font = termFont
        terminalView.nativeForegroundColor = .white
        terminalView.nativeBackgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)

        // Build environment
        var env: [String] = []
        let loginPATH = resolveLoginPATH()
        env.append("PATH=\(loginPATH)")
        env.append("TERM=xterm-256color")
        env.append("HOME=\(NSHomeDirectory())")
        env.append("USER=\(NSUserName())")
        env.append("LANG=en_US.UTF-8")
        // Mark as managed by NotchBar so hooks can identify these sessions
        env.append("NOTCHBAR_MANAGED=1")

        // Preserve useful env vars from parent
        for key in ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY", "EDITOR", "VISUAL", "SSH_AUTH_SOCK"] {
            if let val = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(val)")
            }
        }

        // Store references
        lock.lock()
        terminalViews[sessionId] = terminalView
        lock.unlock()

        // Set up process exit callback — must retain the handler strongly
        let exitHandler = ProcessExitHandler(sessionId: sessionId) { [weak self] sid, exitCode in
            log.info("Claude process exited for session \(sid) with code \(exitCode)")
            self?.lock.lock()
            self?.sessionPIDs.removeValue(forKey: sid)
            self?.lock.unlock()
            DispatchQueue.main.async { onProcessExit(sid, exitCode) }
        }
        // Store strongly so it isn't deallocated (processDelegate is weak)
        lock.lock()
        exitHandlers[sessionId] = exitHandler
        lock.unlock()
        terminalView.processDelegate = exitHandler

        terminalView.startProcess(
            executable: claudePath,
            args: args,
            environment: env,
            execName: "claude",
            currentDirectory: cwd
        )

        let pid = terminalView.process.shellPid
        if pid > 0 {
            lock.lock()
            sessionPIDs[sessionId] = pid
            lock.unlock()
            log.info("Started claude session \(sessionId) with PID \(pid) in \(cwd)")
        }

        return terminalView
    }

    /// Get the terminal view for a session.
    func terminalView(for sessionId: UUID) -> LocalProcessTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return terminalViews[sessionId]
    }

    /// Terminate a session's process.
    func terminateSession(_ sessionId: UUID) {
        lock.lock()
        let pid = sessionPIDs[sessionId]
        lock.unlock()

        if let pid = pid {
            if kill(pid, SIGTERM) == 0 {
                log.info("Sent SIGTERM to PID \(pid) for session \(sessionId)")
            } else if errno != ESRCH {
                // ESRCH = process already dead, which is fine
                log.warning("Failed to send SIGTERM to PID \(pid): \(String(cString: strerror(errno)))")
            }
        }

        cleanup(sessionId)
    }

    /// Clean up resources for a session (view + PID tracking + exit handler).
    func cleanup(_ sessionId: UUID) {
        lock.lock()
        terminalViews.removeValue(forKey: sessionId)
        sessionPIDs.removeValue(forKey: sessionId)
        exitHandlers.removeValue(forKey: sessionId)
        lock.unlock()
    }

    /// Check if a session's process is still running.
    func isAlive(_ sessionId: UUID) -> Bool {
        lock.lock()
        let pid = sessionPIDs[sessionId]
        lock.unlock()
        guard let pid = pid else { return false }
        return kill(pid, 0) == 0
    }
}

// MARK: - Process Exit Delegate

/// Bridges SwiftTerm's process exit notification to our callback system.
class ProcessExitHandler: NSObject, LocalProcessTerminalViewDelegate {
    let sessionId: UUID
    let onExit: (UUID, Int32) -> Void

    init(sessionId: UUID, onExit: @escaping (UUID, Int32) -> Void) {
        self.sessionId = sessionId
        self.onExit = onExit
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit(sessionId, exitCode ?? -1)
    }
}
