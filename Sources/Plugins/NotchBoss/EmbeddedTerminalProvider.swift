import Foundation
import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "embedded-terminal")

/// Plugin that launches Claude Code sessions with an embedded terminal.
/// Instead of monitoring external terminal sessions, this spawns claude directly
/// via PTY and renders the full terminal UI inside NotchBar's panel.
class EmbeddedTerminalProvider: AgentProviderController {
    let state: NotchState
    private var pollTimer: Timer?

    let descriptor = ProviderDescriptor(
        id: .embeddedTerminal,
        displayName: "Embedded Terminal",
        shortName: "Terminal",
        executableName: "claude",
        settingsPath: nil,
        instructionsFileName: "CLAUDE.md",
        integrationTitle: "Embedded Terminal",
        installActionTitle: "Install",
        removeActionTitle: "Remove",
        integrationSummary: "Launch Claude Code sessions directly inside NotchBar with a built-in terminal.",
        accentColor: brandOrange,
        statusColor: brandOrange,
        symbolName: "terminal.fill",
        capabilities: ProviderCapabilities(
            liveApprovals: false,  // Approvals happen inline in the terminal
            liveReasoning: false,
            sessionHistory: true,
            integrationInstall: false
        ),
        description: "Launch Claude Code with a built-in terminal. Interact directly from the notch panel.",
        stability: .beta,
        defaultEnabled: true
    )

    init(state: NotchState) {
        self.state = state
    }

    // MARK: - Lifecycle

    func start() {
        log.info("Embedded terminal provider started")
        // Poll to update session status (alive/dead) every 3 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollSessions()
        }
    }

    func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Terminate all managed sessions
        for session in managedSessions {
            PTYSessionManager.shared.terminateSession(session.id)
        }
    }

    // MARK: - Session Management

    private var managedSessions: [AgentSession] {
        state.sessions.filter { $0.providerID == .embeddedTerminal }
    }

    /// Launch a new Claude Code session in the given directory.
    /// Must be called from the main thread (creates NSView).
    func launchSession(cwd: String, args: [String] = []) {
        dispatchPrecondition(condition: .notOnQueue(.global()))

        let projectName = (cwd as NSString).lastPathComponent
        let session = AgentSession(name: projectName, projectPath: cwd, providerID: .embeddedTerminal)
        session.isActive = true
        session.statusMessage = "Starting..."

        guard let terminalView = PTYSessionManager.shared.createSession(
            sessionId: session.id,
            cwd: cwd,
            args: args,
            onProcessExit: { [weak self] sessionId, exitCode in
                self?.handleProcessExit(sessionId: sessionId, exitCode: exitCode)
            }
        ) else {
            log.error("Failed to create PTY session — claude binary not found")
            session.statusMessage = "Error: claude not found"
            session.isActive = false
            state.sessions.append(session)
            // Auto-remove error sessions after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.state.removeSession(session)
            }
            return
        }

        // Store terminal view reference on the session
        session.embeddedTerminalView = terminalView
        session.terminalAvailable = true
        session.statusMessage = "Running"

        state.sessions.append(session)
        // Auto-expand the new session
        let idx = state.sessions.count - 1
        state.selectCard(idx)
        // Expand the panel on the main screen
        if let mainScreen = NSScreen.main {
            state.expandedScreenID = mainScreen.displayID
        }
        log.info("Launched embedded session '\(projectName)' in \(cwd)")
    }

    /// Called from PTYSessionManager on main thread via DispatchQueue.main.async
    private func handleProcessExit(sessionId: UUID, exitCode: Int32) {
        guard let session = state.sessions.first(where: { $0.id == sessionId }) else { return }
        session.isActive = false
        session.isCompleted = true
        session.statusMessage = exitCode == 0 ? "Completed" : "Exited (\(exitCode))"
        state.objectWillChange.send()
        PTYSessionManager.shared.cleanup(sessionId)
    }

    /// Timer fires on main run loop — safe to touch @Published properties
    private func pollSessions() {
        for session in managedSessions where session.isActive {
            if !PTYSessionManager.shared.isAlive(session.id) {
                session.isActive = false
                session.isCompleted = true
                session.statusMessage = "Completed"
                state.objectWillChange.send()
                PTYSessionManager.shared.cleanup(session.id)
            }
        }
    }

    // MARK: - Session History

    func listPastSessions() -> [PastSession] {
        SessionHistoryManager.shared.listPastSessions()
    }

    func resumeSession(_ session: PastSession) {
        launchSession(cwd: session.projectPath, args: ["--resume"])
    }
}
