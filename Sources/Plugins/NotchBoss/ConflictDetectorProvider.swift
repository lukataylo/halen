import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "conflict-detector")

/// Plugin that monitors file locks across all active agent sessions and detects
/// when two agents (or an agent and an editor) try to modify the same file.
///
/// Also provides an MCP server that agents can connect to for proactive coordination:
/// claim_file, release_file, list_locks, get_context.
class ConflictDetectorProvider: AgentProviderController {
    let state: NotchState
    let coordination = CoordinationEngine.shared
    private var fileWatcher: FileWatcher?
    private var maintenanceTimer: Timer?
    private var mcpStateTimer: Timer?

    private let binDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchbar/bin")
    }()

    private let stateDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchbar/coordination")
    }()

    let descriptor = ProviderDescriptor(
        id: .conflicts,
        displayName: "Conflict Detector",
        shortName: "Conflicts",
        executableName: "",
        settingsPath: "~/.claude/settings.json",
        instructionsFileName: "",
        integrationTitle: "Coordination server",
        installActionTitle: "Set Up Server",
        removeActionTitle: "Remove Server",
        integrationSummary: "Adds a coordination server so agents can claim files and avoid editing the same file at the same time.",
        accentColor: .red,
        statusColor: .red,
        symbolName: "exclamationmark.triangle.fill",
        capabilities: ProviderCapabilities(
            liveApprovals: false,
            liveReasoning: false,
            sessionHistory: false,
            integrationInstall: true
        ),
        description: "Multi-agent file conflict detection with MCP coordination server.",
        stability: .beta,
        defaultEnabled: true
    )

    init(state: NotchState) {
        self.state = state
    }

    // MARK: - Lifecycle

    func start() {
        log.info("Conflict detector started")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        writeMCPServer()

        // Start the file watcher for external modification detection
        fileWatcher = FileWatcher(coordination: coordination)
        fileWatcher?.start()

        // Maintenance timer: expire stale locks and old conflicts
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.coordination.expireStaleLocks()
            self?.coordination.expireOldConflicts()
        }

        // Write MCP state file periodically so the MCP server can read it
        writeMCPState()
        mcpStateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.writeMCPState()
            self?.pollMCPEvents()
        }
    }

    func cleanup() {
        fileWatcher?.stop()
        fileWatcher = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        mcpStateTimer?.invalidate()
        mcpStateTimer = nil
    }

    // MARK: - Integration Install/Remove

    func installIntegration() -> Bool {
        writeMCPServer()
        return installMCPConfig()
    }

    func removeIntegration() -> Bool {
        removeMCPConfig()
    }

    // MARK: - Integration Points

    /// Called by ClaudeCodeBridge (or any provider) when a tool-use event is processed.
    func onToolUse(toolName: String, filePath: String?, agentType: String, session: AgentSession) {
        if let path = filePath {
            fileWatcher?.recordAgentWrite(path)
        }

        guard let path = filePath else { return }
        let conflict = coordination.evaluateToolUse(
            toolName: toolName,
            filePath: path,
            agentType: agentType,
            sessionName: session.name,
            sessionId: session.id.uuidString
        )

        if let conflict = conflict {
            log.warning("Conflict detected: \(conflict.blockedAgent) blocked on \(conflict.fileName) (owned by \(conflict.ownerAgent))")
        }
    }

    /// Called when a session ends — release all its file locks.
    func onSessionEnded(_ session: AgentSession) {
        coordination.releaseAllForSession(session.id.uuidString)
    }

    // MARK: - MCP State File (read by the Python MCP server)

    private func writeMCPState() {
        let locks = coordination.activeLocks.values.map { lock in
            [
                "file_path": lock.filePath,
                "agent_type": lock.agentType,
                "session_name": lock.sessionName,
                "session_id": lock.sessionId,
                "claimed_at": ISO8601DateFormatter().string(from: lock.claimedAt),
            ]
        }

        let sessions = state.sessions.map { s in
            [
                "id": s.id.uuidString,
                "name": s.name,
                "provider": s.providerID.rawValue,
                "project_path": s.projectPath,
                "is_active": s.isActive ? "true" : "false",
                "status": s.statusMessage,
            ]
        }

        let stateDict: [String: Any] = [
            "locks": locks,
            "sessions": sessions,
            "stats": [
                "conflicts_prevented": coordination.stats.conflictsPrevented,
                "files_coordinated": coordination.stats.filesCoordinated,
                "active_locks": coordination.activeLocks.count,
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: stateDict, options: []) else { return }
        try? data.write(to: stateDir.appendingPathComponent("mcp_state.json"))
    }

    /// Poll for MCP conflict events (written by the Python MCP server when claim_file conflicts)
    private func pollMCPEvents() {
        let eventsDir = stateDir.appendingPathComponent("events")
        let fm = FileManager.default
        guard fm.fileExists(atPath: eventsDir.path),
              let files = try? fm.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let filePath = event["file_path"],
                  let ownerAgent = event["owner_agent"],
                  let blockedAgent = event["blocked_agent"] else {
                continue
            }

            let conflict = FileConflict(
                filePath: filePath,
                ownerAgent: ownerAgent,
                ownerSession: event["owner_session"] ?? ownerAgent,
                blockedAgent: blockedAgent,
                blockedSession: event["blocked_session"] ?? blockedAgent,
                isExternal: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.coordination.activeConflicts.removeAll { $0.filePath == filePath }
                self.coordination.activeConflicts.append(conflict)
                self.coordination.stats.conflictsPrevented += 1
            }

            try? fm.removeItem(at: file)
        }
    }

    // MARK: - MCP Server Script

    @discardableResult
    func writeMCPServer() -> Bool {
        let script = Self.mcpServerScript(stateDir: stateDir.path)
        let url = binDir.appendingPathComponent("notchbar-mcp")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            log.info("Wrote MCP server script to \(url.path)")
            return true
        } catch {
            log.error("Failed to write MCP server: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - MCP Config (settings.json)

    @discardableResult
    func installMCPConfig() -> Bool {
        let mcpPath = binDir.appendingPathComponent("notchbar-mcp").path
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

        var settings: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.error("settings.json corrupted — refusing to modify")
                return false
            }
            settings = parsed
        } else {
            settings = [:]
        }

        var mcpServers = settings["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["notchbar-coordination"] = [
            "command": "python3",
            "args": [mcpPath],
        ]
        settings["mcpServers"] = mcpServers

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
            try data.write(to: url)
            log.info("Installed MCP coordination server in settings.json")
            return true
        } catch {
            log.error("Failed to install MCP config: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeMCPConfig() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard var settings = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            return false
        }

        if var mcpServers = settings["mcpServers"] as? [String: Any] {
            mcpServers.removeValue(forKey: "notchbar-coordination")
            if mcpServers.isEmpty {
                settings.removeValue(forKey: "mcpServers")
            } else {
                settings["mcpServers"] = mcpServers
            }
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
            try data.write(to: url)
            log.info("Removed MCP coordination server from settings.json")
            return true
        } catch {
            log.error("Failed to remove MCP config: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Python MCP Server Source

    static func mcpServerScript(stateDir: String) -> String {
        let escapedDir = stateDir.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
#!/usr/bin/env python3
\"\"\"NotchBar Coordination MCP Server

A Model Context Protocol (MCP) server that lets AI agents coordinate file access.
Agents can claim files before editing, check what's locked, and share context.

Communication: JSON-RPC 2.0 over stdio.
State: reads/writes JSON files under \(escapedDir)
\"\"\"

import json, sys, os, datetime

STATE_DIR = "\(escapedDir)"
LOCKS_FILE = os.path.join(STATE_DIR, "file_locks.json")
MCP_STATE_FILE = os.path.join(STATE_DIR, "mcp_state.json")
CONTEXT_FILE = os.path.join(STATE_DIR, "context.json")
EVENTS_DIR = os.path.join(STATE_DIR, "events")
LOCK_EXPIRY_SECONDS = 300

os.makedirs(EVENTS_DIR, exist_ok=True)

def log(msg):
    print(msg, file=sys.stderr)

def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return default if default is not None else {}

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

def read_locks():
    state = read_json(MCP_STATE_FILE, {"locks": []})
    now = datetime.datetime.now(datetime.timezone.utc)
    locks = {}
    for lock in state.get("locks", []):
        try:
            claimed = datetime.datetime.fromisoformat(lock["claimed_at"].replace("Z", "+00:00"))
            if (now - claimed).total_seconds() < LOCK_EXPIRY_SECONDS:
                locks[lock["file_path"]] = lock
        except:
            continue
    return locks

def write_conflict_event(file_path, owner, blocked_agent, blocked_session):
    event = {
        "file_path": file_path,
        "owner_agent": owner.get("agent_type", "unknown"),
        "owner_session": owner.get("session_name", "unknown"),
        "blocked_agent": blocked_agent,
        "blocked_session": blocked_session,
    }
    event_file = os.path.join(EVENTS_DIR, f"conflict-{datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')}.json")
    write_json(event_file, event)

def handle_claim_file(params):
    file_path = params.get("file_path", "")
    agent_type = params.get("agent_type", "unknown")
    session_name = params.get("session_name", "unknown")
    session_id = params.get("session_id", "unknown")

    if not file_path:
        return {"content": [{"type": "text", "text": "Error: file_path is required"}]}

    locks = read_locks()
    normalized = os.path.normpath(file_path)

    if normalized in locks:
        existing = locks[normalized]
        if existing.get("session_id") == session_id:
            return {"content": [{"type": "text", "text": f"OK: You already own the lock on {normalized}"}]}
        write_conflict_event(normalized, existing, agent_type, session_name)
        owner = existing.get("session_name", existing.get("agent_type", "another agent"))
        return {"content": [{"type": "text", "text": f"BLOCKED: {normalized} is locked by {owner} ({existing.get('agent_type', 'unknown')}). Wait for them to finish or work on a different file."}]}

    # Write a lock claim — the Swift app will pick it up via state polling
    locks[normalized] = {
        "file_path": normalized,
        "agent_type": agent_type,
        "session_name": session_name,
        "session_id": session_id,
        "claimed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    write_json(LOCKS_FILE, list(locks.values()))
    return {"content": [{"type": "text", "text": f"OK: Claimed lock on {normalized}"}]}

def handle_release_file(params):
    file_path = params.get("file_path", "")
    session_id = params.get("session_id", "unknown")
    if not file_path:
        return {"content": [{"type": "text", "text": "Error: file_path is required"}]}
    normalized = os.path.normpath(file_path)
    locks = read_locks()
    if normalized in locks and locks[normalized].get("session_id") == session_id:
        del locks[normalized]
        write_json(LOCKS_FILE, list(locks.values()))
        return {"content": [{"type": "text", "text": f"OK: Released lock on {normalized}"}]}
    return {"content": [{"type": "text", "text": f"OK: No lock held by you on {normalized}"}]}

def handle_list_locks(params):
    locks = read_locks()
    if not locks:
        return {"content": [{"type": "text", "text": "No files are currently locked."}]}
    lines = ["Currently locked files:"]
    for path, lock in sorted(locks.items()):
        lines.append(f"  {path} — {lock.get('agent_type', '?')}/{lock.get('session_name', '?')}")
    return {"content": [{"type": "text", "text": "\\n".join(lines)}]}

def handle_get_context(params):
    state = read_json(MCP_STATE_FILE, {})
    sessions = state.get("sessions", [])
    locks = state.get("locks", [])
    stats = state.get("stats", {})
    lines = [f"Active sessions: {len(sessions)}", f"Active locks: {len(locks)}", f"Conflicts prevented: {stats.get('conflicts_prevented', 0)}"]
    for s in sessions:
        status = "active" if s.get("is_active") == "true" else "inactive"
        lines.append(f"  [{s.get('provider', '?')}] {s.get('name', '?')} — {status} — {s.get('status', '')}")
    if locks:
        lines.append("Locked files:")
        for l in locks:
            lines.append(f"  {l.get('file_path', '?')} — {l.get('agent_type', '?')}/{l.get('session_name', '?')}")
    return {"content": [{"type": "text", "text": "\\n".join(lines)}]}

TOOLS = {
    "claim_file": {
        "description": "Claim a file before editing it. If another agent already holds the lock, you will be blocked. Always call this before writing to a file to avoid conflicts.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Absolute path to the file to claim"},
                "agent_type": {"type": "string", "description": "Your agent type (e.g. claude, codex, cursor)"},
                "session_name": {"type": "string", "description": "Your session/project name"},
                "session_id": {"type": "string", "description": "Your unique session ID"},
            },
            "required": ["file_path"],
        },
        "handler": handle_claim_file,
    },
    "release_file": {
        "description": "Release your lock on a file so other agents can edit it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Absolute path to release"},
                "session_id": {"type": "string", "description": "Your unique session ID"},
            },
            "required": ["file_path"],
        },
        "handler": handle_release_file,
    },
    "list_locks": {
        "description": "List all currently locked files and which agent holds each lock.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": handle_list_locks,
    },
    "get_context": {
        "description": "Get an overview of all active agent sessions, locked files, and coordination stats. Use this to understand what other agents are working on.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": handle_get_context,
    },
}

def handle_request(request):
    method = request.get("method", "")
    req_id = request.get("id")
    params = request.get("params", {})

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": req_id, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "notchbar-coordination", "version": "1.0.0"},
        }}
    elif method == "notifications/initialized":
        return None
    elif method == "tools/list":
        tool_list = []
        for name, tool in TOOLS.items():
            tool_list.append({"name": name, "description": tool["description"], "inputSchema": tool["inputSchema"]})
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": tool_list}}
    elif method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        if tool_name in TOOLS:
            result = TOOLS[tool_name]["handler"](arguments)
            return {"jsonrpc": "2.0", "id": req_id, "result": result}
        return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"}}
    elif method == "shutdown":
        return {"jsonrpc": "2.0", "id": req_id, "result": None}
    else:
        if req_id is not None:
            return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}
        return None

def main():
    log("NotchBar MCP Coordination Server starting...")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle_request(request)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
"""
    }
}

// MARK: - Conflict Banner View (shown in the expanded panel)

struct ConflictBanner: View {
    @ObservedObject var coordination: CoordinationEngine

    var body: some View {
        if !coordination.activeConflicts.isEmpty {
            VStack(spacing: 4) {
                ForEach(coordination.activeConflicts) { conflict in
                    ConflictRow(conflict: conflict, coordination: coordination)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

struct ConflictRow: View {
    let conflict: FileConflict
    let coordination: CoordinationEngine

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 1) {
                Text(conflict.fileName)
                    .font(.matrix(11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("\(conflict.ownerAgent) owns · \(conflict.blockedAgent) \(conflict.isExternal ? "modified" : "blocked")")
                    .font(.matrixMono(9))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Text(conflict.age)
                .font(.matrixMono(9))
                .foregroundColor(.white.opacity(0.25))

            if hovering {
                HStack(spacing: 4) {
                    Button {
                        coordination.resolveConflict(conflict, keepOwner: true)
                    } label: {
                        Text("Keep")
                            .font(.matrix(9, weight: .semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        coordination.resolveConflict(conflict, keepOwner: false)
                    } label: {
                        Text("Allow")
                            .font(.matrix(9, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
        )
        .cornerRadius(6)
        .onHover { hovering = $0 }
    }
}
