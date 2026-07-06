import Foundation
import os.log

private let codexLog = Logger(subsystem: "com.dadiani.halen", category: "codex")

final class CodexProvider: AgentProviderController {
    let descriptor = ProviderDescriptor(
        id: .codex,
        displayName: "Codex",
        shortName: "Codex",
        executableName: "codex",
        settingsPath: "~/.codex/config.toml",
        instructionsFileName: "AGENTS.md",
        integrationTitle: "Codex profile",
        installActionTitle: "Install Profile",
        removeActionTitle: "Remove Profile",
        integrationSummary: "Install a managed `notchbar` profile in Codex config with recommended workspace-write, on-request approval preset.",
        accentColor: codexBlue,
        statusColor: brandSuccess,
        symbolName: "terminal",
        capabilities: ProviderCapabilities(
            liveApprovals: false,
            liveReasoning: true,
            sessionHistory: true,
            integrationInstall: true
        ),
        description: "Process discovery and transcript monitoring for OpenAI Codex sessions.",
        stability: .beta,
        defaultEnabled: false
    )

    private let state: NotchState
    private var pollTimer: Timer?
    private var sessionLifecycleTimer: Timer?
    private var knownSessionFiles: [String: URL] = [:]
    private let managedProfileStart = "# BEGIN NOTCHBAR CODEX PROFILE"
    private let managedProfileEnd = "# END NOTCHBAR CODEX PROFILE"

    init(state: NotchState) {
        self.state = state
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.detectRunningSessions()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.shared.transcriptPollInterval, repeats: true) { [weak self] _ in
            // Transcript polling touches @Published properties — keep on main.
            // Detection runs heavy I/O so dispatch off main.
            self?.pollSessions()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.detectRunningSessions()
            }
        }
        sessionLifecycleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.checkSessionLifecycle()
            }
        }
    }

    func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionLifecycleTimer?.invalidate()
        sessionLifecycleTimer = nil
    }

    func listPastSessions() -> [PastSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let files = try? allSessionFiles(in: root) else { return [] }

        return files.compactMap { url in
            let sessionID = Self.sessionID(from: url.lastPathComponent)
            let metadata = CodexTranscriptReader.readSessionMetadata(from: url.path)
            guard let metadata else { return nil }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return PastSession(
                id: sessionID ?? url.deletingPathExtension().lastPathComponent,
                providerID: .codex,
                projectPath: metadata.cwd,
                projectName: (metadata.cwd as NSString).lastPathComponent,
                lastModified: modDate
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    func resumeSession(_ session: PastSession) {
        let profileFlag = hasInstalledManagedProfile() ? "-p notchbar " : ""
        let command = "cd \"\(session.projectPath)\" && codex \(profileFlag)resume \(session.id)"
        TerminalHelper.runCommand(command)
    }

    func installIntegration() -> Bool {
        let url = codexConfigURL()
        let block = """
\(managedProfileStart)
[profiles.notchbar]
approval_policy = "on-request"
sandbox_mode = "workspace-write"
model_reasoning_effort = "medium"
\(managedProfileEnd)
"""

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Validate: check for orphaned managed markers
            let hasStart = existing.contains(managedProfileStart)
            let hasEnd = existing.contains(managedProfileEnd)
            if hasStart != hasEnd {
                codexLog.error("config.toml has orphaned NotchBar markers — refusing to modify")
                return false
            }
            let stripped = stripManagedProfile(from: existing)
            let separator = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            let updated = stripped.trimmingCharacters(in: .whitespacesAndNewlines) + separator + block + "\n"
            try updated.write(to: url, atomically: true, encoding: .utf8)
            codexLog.info("Installed NotchBar Codex profile at \(url.path)")
            return true
        } catch {
            codexLog.error("Failed to install Codex profile: \(error.localizedDescription)")
            return false
        }
    }

    func removeIntegration() -> Bool {
        let url = codexConfigURL()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = stripManagedProfile(from: existing).trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if updated.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try "".write(to: url, atomically: true, encoding: .utf8)
                }
            } else {
                try (updated + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            codexLog.info("Removed NotchBar Codex profile from \(url.path)")
            return true
        } catch {
            codexLog.error("Failed to remove Codex profile: \(error.localizedDescription)")
            return false
        }
    }

    /// Detect running codex processes and create/update sessions.
    /// Called from a background thread — dispatches UI mutations to main.
    private func detectRunningSessions() {
        let pids = Shell.pgrep(descriptor.executableName)
        guard !pids.isEmpty else { return }

        // Heavy I/O: resolve CWDs and scan session files on background thread
        var discovered: [(pid: Int32, cwd: String, name: String)] = []
        for pid in pids {
            guard let cwd = Shell.cwd(for: pid),
                  cwd.hasPrefix("/Users/"),
                  !cwd.contains("/Library/"),
                  cwd.components(separatedBy: "/").count >= 4 else { continue }
            let projectName = (cwd as NSString).lastPathComponent
            discovered.append((pid: pid, cwd: cwd, name: projectName))
        }
        guard !discovered.isEmpty else { return }

        let latestByPath = latestSessionFilesByProjectPath()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for item in discovered {
                let existing = self.existingSession(for: item.cwd)
                let session = existing ?? AgentSession(name: item.name, projectPath: item.cwd, providerID: .codex)

                if existing == nil {
                    session.isActive = true
                    session.statusMessage = "Connected"
                    session.startedAt = Date()
                    session.pid = item.pid
                    self.state.sessions.append(session)
                }

                session.pid = item.pid
                session.isActive = true
                session.isCompleted = false

                if session.instructionsContent == nil {
                    self.readInstructions(for: session)
                }

                if let sessionFile = latestByPath[item.cwd] {
                    self.knownSessionFiles[item.cwd] = sessionFile
                    if session.transcriptPath != sessionFile.path {
                        session.transcriptPath = sessionFile.path
                        session.transcriptReader = CodexTranscriptReader(path: sessionFile.path)
                    }
                }
            }

            if self.state.activeSession == nil && !self.state.sessions.isEmpty {
                self.state.activeSessionIndex = 0
            }
        }
    }

    private func pollSessions() {
        var changed = false

        for session in state.sessions where session.providerID == .codex {
            if let file = knownSessionFiles[session.projectPath], session.transcriptReader == nil {
                session.transcriptPath = file.path
                session.transcriptReader = CodexTranscriptReader(path: file.path)
            }

            guard let reader = session.transcriptReader else { continue }
            let entries = reader.readNew()
            if entries.isEmpty { continue }
            changed = true

            for entry in entries {
                switch entry {
                case .reasoning(let text):
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        session.lastReasoning = String(clean.prefix(180))
                        session.statusMessage = "Thinking"
                        session.isWaitingForUser = false
                    }
                case .usage(let input, let output):
                    session.inputTokens = input
                    session.outputTokens = output
                    session.updateCost()
                case .userMessage:
                    session.isWaitingForUser = false
                    session.isActive = true
                    session.isCompleted = false
                case .modelInfo(let model):
                    session.modelName = model
                    session.updateCost()
                case .status(let status):
                    session.statusMessage = status
                case .response(let text):
                    session.lastResponse = text
                case .turnStarted:
                    session.isActive = true
                    session.isCompleted = false
                    session.isWaitingForUser = false
                    session.statusMessage = "Working"
                case .waitingForInput:
                    session.isWaitingForUser = true
                    session.statusMessage = "Waiting for input"
                case .taskStarted(let event):
                    session.isActive = true
                    session.isCompleted = false
                    session.isWaitingForUser = false
                    session.statusMessage = event.title
                    applyTaskEvent(event, status: .running, to: session)
                case .taskCompleted(let event):
                    session.isActive = true
                    session.isWaitingForUser = false
                    applyTaskEvent(event, status: .completed, to: session)
                case .sessionCompleted:
                    session.isCompleted = true
                    session.isActive = false
                    session.progress = 1.0
                    session.statusMessage = "Completed"
                    session.isWaitingForUser = false
                }
            }
        }

        if changed { state.objectWillChange.send() }
    }

    private func applyTaskEvent(_ event: TranscriptTaskEvent, status: TaskItem.TaskStatus, to session: AgentSession) {
        if let index = session.tasks.lastIndex(where: { $0.requestId == event.id }) {
            session.tasks[index].status = status
            session.tasks[index].detail = event.detail
        } else {
            session.appendTask(TaskItem(
                title: event.title,
                status: status,
                detail: event.detail,
                toolName: event.toolName,
                filePath: event.filePath,
                requestId: event.id
            ))
        }
    }

    private func existingSession(for projectPath: String) -> AgentSession? {
        state.sessions.first { $0.projectPath == projectPath && $0.providerID == .codex }
    }

    /// Called from background thread — pgrep is I/O, then dispatches UI changes to main.
    private func checkSessionLifecycle() {
        let activePids = Set(Shell.pgrep(descriptor.executableName))
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var changed = false
            for session in self.state.sessions where session.providerID == .codex && session.isActive {
                if let pid = session.pid, !activePids.contains(pid) {
                    session.isCompleted = true
                    session.isActive = false
                    session.isWaitingForUser = false
                    session.progress = 1.0
                    session.statusMessage = "Completed"
                    changed = true
                }
            }
            if changed { self.state.objectWillChange.send() }
        }
    }

    private func latestSessionFilesByProjectPath() -> [String: URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let files = try? allSessionFiles(in: root) else { return [:] }

        var map: [String: (url: URL, date: Date)] = [:]
        for url in files {
            guard let metadata = CodexTranscriptReader.readSessionMetadata(from: url.path) else { continue }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let existing = map[metadata.cwd], existing.date >= modDate {
                continue
            }
            map[metadata.cwd] = (url, modDate)
        }

        return map.mapValues(\.url)
    }

    private func allSessionFiles(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        var files: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "jsonl" else { continue }
            files.append(item)
        }
        return files
    }

    private func readInstructions(for session: AgentSession) {
        Shell.readFirstExisting([
            session.projectPath + "/AGENTS.md",
            session.projectPath + "/.codex/AGENTS.md",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/AGENTS.md").path
        ]) { session.instructionsContent = $0 }
    }

    private func codexConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    private func hasInstalledManagedProfile() -> Bool {
        guard let text = try? String(contentsOf: codexConfigURL(), encoding: .utf8) else { return false }
        return text.contains(managedProfileStart) && text.contains(managedProfileEnd)
    }

    private func stripManagedProfile(from text: String) -> String {
        let pattern = "\(NSRegularExpression.escapedPattern(for: managedProfileStart))[\\s\\S]*?\(NSRegularExpression.escapedPattern(for: managedProfileEnd))\\n?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func sessionID(from filename: String) -> String? {
        guard let range = filename.range(of: "[0-9a-f]{8,}-[0-9a-f-]+", options: .regularExpression) else {
            return nil
        }
        return String(filename[range])
    }
}
