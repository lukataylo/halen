import Foundation
import AppKit
import os.log
import UserNotifications
import ApplicationServices

private let log = Logger(subsystem: "com.dadiani.halen", category: "bridge")

// MARK: - Bridge

class ClaudeCodeBridge: AgentProviderController {
    static var shared: ClaudeCodeBridge?
    let descriptor = ProviderDescriptor(
        id: .claude,
        displayName: "Claude Code",
        shortName: "Claude",
        executableName: "claude",
        settingsPath: "~/.claude/settings.json",
        instructionsFileName: "CLAUDE.md",
        integrationTitle: "Claude connection",
        installActionTitle: "Connect",
        removeActionTitle: "Disconnect",
        integrationSummary: "Connects NotchBar to Claude Code so you can see tool calls and approve them from the notch.",
        accentColor: brandOrange,
        statusColor: brandSuccess,
        symbolName: "sparkles.rectangle.stack",
        capabilities: ProviderCapabilities(
            liveApprovals: true,
            liveReasoning: true,
            sessionHistory: true,
            integrationInstall: true
        ),
        description: "Live monitoring, approval cards, and tool timeline for Claude Code sessions.",
        stability: .stable
    )

    let binDir: URL
    let state: NotchState

    private let lock = NSLock()
    private var _sessionMap: [String: UUID] = [:]
    private var _runningTools: [String: (sessionUUID: UUID, taskTitle: String)] = [:]

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return block()
    }

    func sessionMapValue(for key: String) -> UUID? { withLock { _sessionMap[key] } }
    func setSessionMap(_ value: UUID, for key: String) { withLock { _sessionMap[key] = value } }
    func setRunningTool(_ value: (sessionUUID: UUID, taskTitle: String), for key: String) { withLock { _runningTools[key] = value } }
    func removeRunningTool(for key: String) -> (sessionUUID: UUID, taskTitle: String)? { withLock { _runningTools.removeValue(forKey: key) } }

    var transcriptTimer: Timer?
    var sessionLifecycleTimer: Timer?
    var gitTimer: Timer?
    var approvalTimers: [String: Timer] = [:]
    var socketServer: SocketServer?
    /// Guarded by responseLock — accessed from socket thread (write) and main thread (read/remove).
    private var pendingResponses: [String: (String) -> Void] = [:]
    private let responseLock = NSLock()

    func setPendingResponse(_ respond: @escaping (String) -> Void, for requestId: String) {
        responseLock.lock(); defer { responseLock.unlock() }
        pendingResponses[requestId] = respond
    }

    func removePendingResponse(for requestId: String) -> ((String) -> Void)? {
        responseLock.lock(); defer { responseLock.unlock() }
        return pendingResponses.removeValue(forKey: requestId)
    }

    init(state: NotchState) {
        self.state = state
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notchbar")
        binDir = base.appendingPathComponent("bin")
        Self.shared = self
    }

    func start() {
        log.info("Bridge initializing")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        writeHookScript()
        requestNotificationPermission()

        // Socket server for IPC with hook scripts
        socketServer = SocketServer()
        socketServer?.onTimeout = { [weak self] event in
            let requestId = event.toolUseId ?? event.requestId ?? ""
            DispatchQueue.main.async {
                _ = self?.removePendingResponse(for: requestId)
                self?.approvalTimers[requestId]?.invalidate()
                self?.approvalTimers.removeValue(forKey: requestId)
                if let session = self?.state.sessions.first(where: { $0.pendingApprovals.contains(where: { $0.requestId == requestId }) }) {
                    session.pendingApprovals.removeAll { $0.requestId == requestId }
                    session.statusMessage = "Timed out (auto-approved)"
                    self?.state.objectWillChange.send()
                }
            }
        }
        socketServer?.start { [weak self] event, hookType, respond in
            self?.handleSocketEvent(event, hookType: hookType, respond: respond)
        }

        transcriptTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.shared.transcriptPollInterval, repeats: true) { [weak self] _ in
            self?.pollTranscripts()
        }

        // Session lifecycle: detect when claude processes exit
        sessionLifecycleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkSessionLifecycle()
        }

        // Git status polling
        gitTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pollGitStatus()
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.detectRunningSessions()
        }
    }

    // MARK: - Notification Permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { log.info("Notification permission granted") }
        }
    }

    func sendNotification(title: String, body: String, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Session Detection

    private func detectRunningSessions() {
        let pids = Shell.pgrep("claude")
        guard !pids.isEmpty else { return }
        log.info("Found \(pids.count) claude process(es)")

        var sessions: [(name: String, path: String, pid: Int32)] = []
        for pid in pids {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard let cwd = Shell.cwd(for: pid),
                  cwd.hasPrefix(home + "/"),
                  !cwd.hasPrefix(home + "/Library/"),
                  !cwd.hasPrefix(home + "/Downloads/"),
                  !cwd.hasPrefix(home + "/Desktop/"),
                  cwd.components(separatedBy: "/").count >= 5 else { continue }
            let name = (cwd as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            sessions.append((name: name, path: cwd, pid: pid))
        }
        // Deduplicate by path (multiple claude processes can share a project)
        var seen = Set<String>()
        sessions = sessions.filter { seen.insert($0.path).inserted }

        guard !sessions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for s in sessions {
                if self.state.sessions.contains(where: { $0.projectPath == s.path && $0.providerID == .claude && !$0.isCompleted }) { continue }
                let session = AgentSession(name: s.name, projectPath: s.path, providerID: .claude)
                session.isActive = true
                session.statusMessage = "Running"
                session.pid = s.pid
                self.state.sessions.append(session)
                // Check terminal availability off main thread
                let pid = s.pid
                DispatchQueue.global(qos: .utility).async {
                    let inTerminal = Shell.isRunningInTerminal(pid: pid)
                    DispatchQueue.main.async { session.terminalAvailable = inTerminal }
                }
                self.readClaudeMd(for: session)
            }
            if !self.state.sessions.isEmpty { self.state.activeSessionIndex = 0 }
            self.state.objectWillChange.send()
        }
    }

    // MARK: - Session Lifecycle

    private func checkSessionLifecycle() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let activePids = Set(Shell.pgrep("claude"))

            DispatchQueue.main.async {
                var changed = false
                for session in self.state.sessions where session.providerID == .claude && session.isActive && !session.isCompleted {
                    if let pid = session.pid, !activePids.contains(pid) {
                        log.info("Session '\(session.name)' (pid \(pid)) completed - process no longer running")
                        session.isCompleted = true
                        session.isActive = false
                        session.statusMessage = "Completed"
                        session.progress = 1.0
                        changed = true
                        // Release file locks for this session
                        if let conflictProvider = ProviderManager.shared?.controller(for: .conflicts) as? ConflictDetectorProvider {
                            conflictProvider.onSessionEnded(session)
                        }
                        if AppSettings.shared.notifySessionComplete {
                            self.sendNotification(title: "Session Complete", body: "\(session.name) finished. \(session.tokenSummary) \(session.costSummary)")
                        }
                    }
                }
                if changed { self.state.objectWillChange.send() }
            }
        }
    }

    // MARK: - CLAUDE.md Reader

    func readClaudeMd(for session: AgentSession) {
        Shell.readFirstExisting([
            session.projectPath + "/CLAUDE.md",
            session.projectPath + "/.claude/CLAUDE.md"
        ]) { session.instructionsContent = $0 }
    }

    // MARK: - Git Status Polling

    private func pollGitStatus() {
        for session in state.sessions where session.isActive && !session.isCompleted {
            GitIntegration.fetchStatus(for: session)
        }
    }

    // MARK: - Socket Event Handler (runs on background thread)

    private func handleSocketEvent(_ event: ClaudeCodeEvent, hookType: String, respond: @escaping (String) -> Void) {
        let toolName = event.toolName ?? "Tool"
        let toolUseId = event.toolUseId ?? event.requestId ?? UUID().uuidString

        if hookType == "pre-tool-use" || hookType == "pretooluse" {
            let shouldAuto = AppSettings.shared.shouldAutoApprove(toolName: toolName)
            // Check session-level auto-approve-all
            let sessionAutoApprove: Bool = {
                guard let sid = event.sessionId, let uuid = sessionMapValue(for: sid),
                      let session = state.sessions.first(where: { $0.id == uuid }) else { return false }
                return session.autoApproveAll
            }()

            // Interactive tools (e.g. AskUserQuestion) always need user interaction
            let category = ToolApprovalCategory.fromToolName(toolName)
            if (shouldAuto || sessionAutoApprove) && category != .interactive {
                respond("{\"decision\":\"approve\"}")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.setPendingResponse(respond, for: toolUseId)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleEvent(event)
        }
    }

    // MARK: - Handle Event (must run on main thread)

    func handleEvent(_ event: ClaudeCodeEvent) {
        guard let sessionId = event.sessionId else {
            log.warning("Received event with no sessionId, ignoring")
            return
        }
        log.info("Event: \(event.hookType ?? event.hookEventName ?? "unknown") tool=\(event.toolName ?? "nil") session=\(String(sessionId.prefix(8)))")

        let cwd = event.cwd ?? ""
        let session: ClaudeSession
        if let uuid = sessionMapValue(for: sessionId), let existing = state.sessions.first(where: { $0.id == uuid }) {
            session = existing
        } else {
            // Only create sessions for real project directories under current user
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard cwd.hasPrefix(home + "/"),
                  !cwd.hasPrefix(home + "/Library/"),
                  !cwd.hasPrefix(home + "/Downloads/"),
                  !cwd.hasPrefix(home + "/Desktop/"),
                  cwd.components(separatedBy: "/").count >= 5,
                  FileManager.default.fileExists(atPath: cwd) else { return }
            let projectName = (cwd as NSString).lastPathComponent
            let s = AgentSession(name: projectName, projectPath: cwd, providerID: .claude)
            s.isActive = true; s.statusMessage = "Connected"
            // Try to find PID and detect terminal
            DispatchQueue.global(qos: .utility).async {
                for pid in Shell.pgrep("claude") {
                    if let pidCwd = Shell.cwd(for: pid), pidCwd == cwd {
                        DispatchQueue.main.async {
                            s.pid = pid
                            s.terminalAvailable = Shell.isRunningInTerminal(pid: pid)
                        }
                        break
                    }
                }
            }
            state.sessions.append(s)
            setSessionMap(s.id, for: sessionId)
            session = s
            if state.sessions.count == 1 { state.activeSessionIndex = 0 }
            readClaudeMd(for: s)
        }

        // Update permission mode from event
        if let mode = event.permissionMode {
            session.permissionMode = mode
        }

        // Set up transcript reader if we have the path
        if let tp = event.transcriptPath, session.transcriptReader == nil {
            session.transcriptPath = tp
            session.transcriptReader = TranscriptReader(path: tp)
        }

        let hookType = event.hookType ?? event.hookEventName?.lowercased() ?? ""
        let toolUseId = event.toolUseId ?? event.requestId ?? UUID().uuidString

        switch hookType {
        case "pre-tool-use", "pretooluse":
            let desc = event.toolDescription
            let toolName = event.toolName ?? "Tool"
            let settings = AppSettings.shared
            let category = ToolApprovalCategory.fromToolName(toolName)
            let needsApproval = category == .interactive || (!settings.shouldAutoApprove(toolName: toolName) && !session.autoApproveAll)

            if needsApproval {
                log.info("Tool '\(toolName)' requires approval (request: \(toolUseId))")
                var approval = PendingApproval(
                    requestId: toolUseId,
                    toolName: toolName,
                    toolDescription: desc,
                    filePath: event.filePath,
                    bashCommand: event.bashCommand,
                    isWriteOperation: event.isWriteOperation
                )
                // Capture content for the approval overlay
                if let input = event.toolInput {
                    approval.fileContent = input["content"]?.stringValue
                    approval.editOldString = input["old_string"]?.stringValue
                    approval.editNewString = input["new_string"]?.stringValue

                    // Parse AskUserQuestion questions
                    if toolName == "AskUserQuestion",
                       let questionsArr = input["questions"]?.arrayValue {
                        approval.interactiveQuestions = questionsArr.compactMap { item in
                            guard let obj = item.objectValue,
                                  let q = obj["question"]?.stringValue else { return nil }
                            let opts = (obj["options"]?.arrayValue ?? []).compactMap { opt -> InteractiveOption? in
                                guard let o = opt.objectValue,
                                      let label = o["label"]?.stringValue,
                                      let desc = o["description"]?.stringValue else { return nil }
                                return InteractiveOption(label: label, description: desc, preview: o["preview"]?.stringValue)
                            }
                            let multi: Bool = {
                                if case .bool(let v) = obj["multiSelect"] { return v }
                                return false
                            }()
                            return InteractiveQuestion(
                                question: q,
                                header: obj["header"]?.stringValue,
                                options: opts,
                                multiSelect: multi
                            )
                        }
                    }
                }
                session.pendingApprovals.append(approval)
                session.appendTask(TaskItem(title: desc, status: .pendingApproval, toolName: toolName, filePath: event.filePath))
                session.statusMessage = "Awaiting approval: \(desc)"

                if state.expandedScreenID == nil {
                    let loc = NSEvent.mouseLocation
                    state.expandedScreenID = (NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main)?.displayID
                }

                if settings.notifyApprovalNeeded {
                    sendNotification(title: "Approval Needed", body: desc)
                }
                settings.playSound("Submarine")

                let timeoutMinutes = settings.approvalTimeoutMinutes
                if timeoutMinutes > 0 {
                    let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeoutMinutes * 60), repeats: false) { [weak self] _ in
                        self?.approveAction(requestId: toolUseId, sessionId: session.id)
                    }
                    approvalTimers[toolUseId] = timer
                }
            } else {
                session.appendTask(TaskItem(title: desc, status: .running, toolName: toolName, filePath: event.filePath))
                session.statusMessage = desc
            }

            session.isWaitingForUser = false
            setRunningTool((sessionUUID: session.id, taskTitle: desc), for: toolUseId)

            // Notify conflict detector of file access
            if let conflictProvider = ProviderManager.shared?.controller(for: .conflicts) as? ConflictDetectorProvider {
                conflictProvider.onToolUse(toolName: toolName, filePath: event.filePath, agentType: "claude", session: session)
            }

        case "post-tool-use", "posttooluse":
            let desc = event.toolDescription

            let detail: String?
            if let r = event.toolResponse {
                detail = r.interrupted == true ? "interrupted" : (r.stderr?.isEmpty == false ? "stderr" : nil)
                if let stdout = r.stdout, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lines = trimmed.components(separatedBy: "\n").suffix(4)
                    session.lastResponse = String(lines.joined(separator: "\n").suffix(200))
                }
            } else { detail = nil }

            if let info = removeRunningTool(for: toolUseId),
               let idx = session.tasks.lastIndex(where: { $0.title == info.taskTitle && ($0.status == .running || $0.status == .pendingApproval) }) {
                session.tasks[idx].status = .completed
                session.tasks[idx].detail = detail
            } else {
                session.appendTask(TaskItem(title: desc, status: .completed, detail: detail, toolName: event.toolName, filePath: event.filePath))
            }
            session.lastToolActivityAt = Date()

            // Clear pending approval if this was it
            session.pendingApprovals.removeAll { $0.requestId == toolUseId }

            // Fetch diff for write operations
            if event.isWriteOperation, let fp = event.filePath {
                fetchDiffForTask(filePath: fp, cwd: session.projectPath, session: session, toolUseId: toolUseId)
            }

            session.statusMessage = desc

        default: break
        }
        state.objectWillChange.send()
    }

    // MARK: - Approval Actions

    func approveAction(requestId: String, sessionId: UUID) {
        resolveApproval(requestId: requestId, sessionId: sessionId, decision: "approve", newStatus: .running)
    }

    func rejectAction(requestId: String, sessionId: UUID) {
        resolveApproval(requestId: requestId, sessionId: sessionId, decision: "deny", reason: "User rejected from NotchBar", newStatus: .rejected)
    }

    private func resolveApproval(requestId: String, sessionId: UUID, decision: String, reason: String? = nil, newStatus: TaskItem.TaskStatus) {
        log.info("\(decision.capitalized) request \(requestId)")

        // Respond via socket if the connection is waiting
        if let respond = removePendingResponse(for: requestId) {
            var json: [String: Any] = ["decision": decision]
            if let reason = reason { json["reason"] = reason }
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                DispatchQueue.global(qos: .userInteractive).async { respond(str) }
            }
        }

        approvalTimers[requestId]?.invalidate()
        approvalTimers.removeValue(forKey: requestId)

        if let session = state.sessions.first(where: { $0.id == sessionId }) {
            if session.pendingApprovals.contains(where: { $0.requestId == requestId }) {
                session.pendingApprovals.removeAll { $0.requestId == requestId }
                if let idx = session.tasks.lastIndex(where: { $0.status == .pendingApproval }) {
                    session.tasks[idx].status = newStatus
                }
                session.statusMessage = decision == "approve" ? "Approved" : "Rejected"
            }
            state.objectWillChange.send()
        }
    }

    // MARK: - Diff Fetching

    private func fetchDiffForTask(filePath: String, cwd: String, session: ClaudeSession, toolUseId: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let diffs = GitIntegration.fetchDiff(filePath: filePath, cwd: cwd)
            guard !diffs.isEmpty else { return }
            DispatchQueue.main.async {
                if let idx = session.tasks.lastIndex(where: { $0.filePath == filePath && $0.status == .completed }) {
                    session.tasks[idx].diffFiles = diffs
                }
                self?.state.objectWillChange.send()
            }
        }
    }

    // MARK: - Transcript Polling

    func pollTranscripts() {
        var changed = false
        for session in state.sessions where session.providerID == .claude && session.isActive {
            guard let reader = session.transcriptReader else { continue }
            let entries = reader.readNew()
            for entry in entries {
                switch entry {
                case .reasoning(let text):
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        let summary: String
                        if let dotIdx = clean.firstIndex(of: "."), clean.distance(from: clean.startIndex, to: dotIdx) < 150 {
                            summary = String(clean[...dotIdx])
                        } else {
                            summary = String(clean.prefix(150))
                        }
                        session.lastReasoning = summary
                        changed = true
                    }
                case .usage(let input, let output):
                    let prevCost = session.estimatedCost
                    session.inputTokens = input
                    session.outputTokens = output
                    session.updateCost()
                    changed = true

                    if AppSettings.shared.showCostTracking {
                        let threshold = AppSettings.shared.costAlertThreshold
                        if session.estimatedCost >= threshold && prevCost < threshold {
                            sendNotification(title: "Cost Alert", body: "\(session.name) has exceeded \(String(format: "$%.2f", threshold))")
                        }
                    }
                case .userMessage:
                    session.isWaitingForUser = false
                    changed = true
                case .modelInfo(let model):
                    session.modelName = model
                    session.updateCost()
                    changed = true
                case .status(let status):
                    session.statusMessage = status
                    changed = true
                case .response(let text):
                    session.lastResponse = text
                    changed = true
                case .turnStarted, .waitingForInput, .taskStarted, .taskCompleted:
                    break
                case .sessionCompleted:
                    session.isCompleted = true
                    session.isActive = false
                    session.progress = 1.0
                    changed = true
                }
            }
        }
        if changed { state.objectWillChange.send() }
    }

    func listPastSessions() -> [PastSession] {
        SessionHistoryManager.shared.listPastSessions()
    }

    func resumeSession(_ session: PastSession) {
        SessionHistoryManager.shared.resumeSession(session)
    }

    // MARK: - Cleanup

    func cleanup() {
        log.info("Bridge cleaning up...")
        // Auto-approve any pending approvals so Claude Code isn't stuck
        for (_, timer) in approvalTimers { timer.invalidate() }
        approvalTimers.removeAll()
        responseLock.lock()
        let pending = pendingResponses
        pendingResponses.removeAll()
        responseLock.unlock()
        for (_, respond) in pending {
            respond("{\"decision\":\"approve\"}")
        }
        socketServer?.stop()
        transcriptTimer?.invalidate()
        sessionLifecycleTimer?.invalidate()
        gitTimer?.invalidate()
        log.info("Bridge cleanup complete")
    }

    // MARK: - Hook Delegation

    func installIntegration() -> Bool { installHooks() }
    func removeIntegration() -> Bool { removeHooks() }

    @discardableResult
    func writeHookScript() -> Bool { HookManager.writeHookScript(to: binDir) }

    @discardableResult
    func installHooks() -> Bool { HookManager.installHooks(binDir: binDir) }

    @discardableResult
    func removeHooks() -> Bool { HookManager.removeHooks() }
}
