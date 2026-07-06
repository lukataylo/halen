import Foundation
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "hooks")

// MARK: - Claude Code Hook Event

struct ClaudeCodeEvent: Codable {
    let sessionId: String?
    let cwd: String?
    let permissionMode: String?
    let hookEventName: String?
    let toolName: String?
    let toolInput: [String: AnyCodableValue]?
    let toolResponse: ToolResponse?
    let toolUseId: String?
    let hookType: String?
    let requestId: String?
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", cwd, permissionMode = "permission_mode"
        case hookEventName = "hook_event_name", toolName = "tool_name"
        case toolInput = "tool_input", toolResponse = "tool_response"
        case toolUseId = "tool_use_id", hookType = "hook_type", requestId = "request_id"
        case transcriptPath = "transcript_path"
    }

    struct ToolResponse: Codable {
        let stdout: String?
        let stderr: String?
        let interrupted: Bool?
    }

    var toolDescription: String {
        guard let input = toolInput else { return toolName ?? "Tool" }
        switch toolName {
        case "Edit": return "Edit \(shortPath(input["file_path"]?.stringValue))"
        case "Write": return "Write \(shortPath(input["file_path"]?.stringValue))"
        case "Read": return "Read \(shortPath(input["file_path"]?.stringValue))"
        case "Bash":
            return input["description"]?.stringValue ?? "Run: \(String((input["command"]?.stringValue ?? "").prefix(50)))"
        case "Glob": return "Search: \(input["pattern"]?.stringValue ?? "")"
        case "Grep": return "Grep: \(input["pattern"]?.stringValue ?? "")"
        case "Agent": return "Agent: \(input["description"]?.stringValue ?? "subagent")"
        case "AskUserQuestion":
            if let questions = input["questions"]?.arrayValue,
               let first = questions.first?.objectValue,
               let q = first["question"]?.stringValue {
                return q
            }
            return "Ask user a question"
        case "NotebookEdit": return "Edit cell \(input["cell_id"]?.stringValue ?? "") in \(shortPath(input["notebook_path"]?.stringValue))"
        case "WebFetch": return "Fetch: \(input["url"]?.stringValue ?? "")"
        case "WebSearch": return "Search: \(input["query"]?.stringValue ?? "")"
        case "Skill": return "Skill: \(input["skill"]?.stringValue ?? "")"
        case "TaskCreate": return input["description"]?.stringValue ?? "Create task"
        case "TaskUpdate": return "Update task: \(input["id"]?.stringValue ?? "")"
        case "TaskGet", "TaskList", "TaskStop", "TaskOutput":
            return "\(toolName ?? "Task"): \(input["id"]?.stringValue ?? input["description"]?.stringValue ?? "")"
        case "ToolSearch": return "Search tools: \(input["query"]?.stringValue ?? "")"
        case "LSP": return "LSP: \(input["operation"]?.stringValue ?? input["command"]?.stringValue ?? "")"
        case "CronCreate": return "Schedule: \(input["description"]?.stringValue ?? input["schedule"]?.stringValue ?? "")"
        case "CronDelete": return "Remove schedule: \(input["id"]?.stringValue ?? "")"
        case "CronList": return "List schedules"
        case "Monitor": return "Monitor: \(input["description"]?.stringValue ?? "")"
        case "ScheduleWakeup": return "Wake in \(input["delaySeconds"]?.stringValue ?? "?")s"
        case "EnterPlanMode", "ExitPlanMode": return toolName ?? "Plan"
        default:
            if let name = toolName, name.hasPrefix("mcp__") {
                let parts = name.split(separator: "__")
                let shortName = parts.count >= 3 ? String(parts.last!) : name
                let desc = input["description"]?.stringValue
                    ?? input["query"]?.stringValue
                    ?? input["command"]?.stringValue
                return desc.map { "\(shortName): \($0)" } ?? shortName
            }
            return toolName ?? "Tool"
        }
    }

    var isWriteOperation: Bool { ["Edit", "Write", "Bash", "NotebookEdit"].contains(toolName) }

    var filePath: String? { toolInput?["file_path"]?.stringValue }
    var bashCommand: String? { toolInput?["command"]?.stringValue }

    private func shortPath(_ path: String?) -> String {
        guard let path = path else { return "file" }
        let parts = path.split(separator: "/")
        return parts.count > 2 ? String(parts.suffix(2).joined(separator: "/")) : path
    }
}

// MARK: - AnyCodableValue

enum AnyCodableValue: Codable {
    case string(String), int(Int), double(Double), bool(Bool)
    case array([AnyCodableValue]), object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode([AnyCodableValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: AnyCodableValue].self) { self = .object(v) }
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var arrayValue: [AnyCodableValue]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: [String: AnyCodableValue]? { if case .object(let v) = self { return v }; return nil }
}

// MARK: - Hook Script Management

/// Manages the NotchBar hook script and Claude Code settings.json integration.
enum HookManager {
    private static let hookScriptContent = """
#!/bin/bash
# NotchBar hook — socket-based IPC for fast approvals
# Falls back to auto-approve if NotchBar is not running.
SOCK="$HOME/.notchbar/notchbar.sock"
HOOK_TYPE="${1:-notification}"
INPUT=$(cat -)

# Inject hook_type into the JSON
EVENT=$(echo "$INPUT" | awk -v ht="$HOOK_TYPE" '
  NR==1 { sub(/^[[:space:]]*\\{/, "{\\"hook_type\\":\\"" ht "\\",") }
  { print }
')

# For post-tool-use: fire-and-forget (no response needed)
if [ "$HOOK_TYPE" != "pre-tool-use" ]; then
    if [ -S "$SOCK" ]; then
        echo "$EVENT" | nc -U -w1 "$SOCK" >/dev/null 2>&1 &
    fi
    exit 0
fi

# For pre-tool-use: send event and wait for approval response
if [ -S "$SOCK" ]; then
    RESPONSE=$(echo "$EVENT" | nc -U -w300 "$SOCK" 2>/dev/null)
    if [ -n "$RESPONSE" ]; then
        echo "$RESPONSE"
        exit 0
    fi
fi

# Socket unavailable (NotchBar not running): auto-approve
echo '{"decision":"approve"}'
"""

    /// Write the hook shell script to ~/.notchbar/bin/notchbar-hook.
    @discardableResult
    static func writeHookScript(to binDir: URL) -> Bool {
        let url = binDir.appendingPathComponent("notchbar-hook")
        do {
            try hookScriptContent.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            log.error("Failed to write hook script: \(error.localizedDescription)")
            return false
        }
    }

    /// Install NotchBar hook entries into Claude's ~/.claude/settings.json.
    /// Preserves existing hooks from other tools.
    @discardableResult
    static func installHooks(binDir: URL) -> Bool {
        let hookPath = binDir.appendingPathComponent("notchbar-hook").path
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

        var settings: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.error("settings.json exists but is corrupted — refusing to overwrite")
                return false
            }
            settings = parsed
        } else {
            settings = [:]
        }

        let notchEntry: (String) -> [String: Any] = { hookType in
            ["matcher": "", "hooks": [["type": "command", "command": "\(hookPath) \(hookType)"]]]
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (key, hookType) in [("PreToolUse", "pre-tool-use"), ("PostToolUse", "post-tool-use")] {
            var entries = hooks[key] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    let cmd = h["command"] as? String ?? ""
                    return cmd.contains("notchbar-hook") || cmd.contains("notchclaude-hook")
                }
            }
            entries.append(notchEntry(hookType))
            hooks[key] = entries
        }
        settings["hooks"] = hooks

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
            try data.write(to: url)
            log.info("Hooks installed successfully (existing hooks preserved)")
            return true
        } catch {
            log.error("Failed to install hooks: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove NotchBar hook entries from Claude's settings.json, preserving other hooks.
    @discardableResult
    static func removeHooks() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard var settings = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            log.error("Failed to read settings.json for hook removal")
            return false
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return true }

        for key in ["PreToolUse", "PostToolUse"] {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains("notchbar-hook") == true
                }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
            try data.write(to: url)
            log.info("NotchBar hooks removed (other hooks preserved)")
            return true
        } catch {
            log.error("Failed to remove hooks: \(error.localizedDescription)")
            return false
        }
    }
}
