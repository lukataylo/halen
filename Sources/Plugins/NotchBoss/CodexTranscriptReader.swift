import Foundation
import os.log

private let codexTranscriptLog = Logger(subsystem: "com.dadiani.halen", category: "codex-transcript")

final class CodexTranscriptReader: LiveTranscriptReader {
    struct Metadata {
        let sessionID: String
        let cwd: String
        let model: String?
    }

    let path: String
    private var lastOffset: UInt64 = 0
    private var partialLine = ""
    private var totalInputTokens = 0
    private var totalOutputTokens = 0
    private var completedCallIDs: Set<String> = []

    init(path: String) {
        self.path = path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            lastOffset = size > 20000 ? size - 20000 : 0
        }
    }

    func readNew() -> [TranscriptEntry] {
        guard let result = Shell.readTail(path: path, from: lastOffset) else { return [] }
        lastOffset = result.newOffset
        let text = result.text

        var entries: [TranscriptEntry] = []
        let jsonLines = Shell.parseJSONLines(text: text, partialLine: &partialLine)

        for json in jsonLines {
            let type = json["type"] as? String ?? ""
            let payload = json["payload"] as? [String: Any] ?? [:]

            switch type {
            case "session_meta":
                if let model = payload["model"] as? String {
                    entries.append(.modelInfo(model))
                }
            case "event_msg":
                parseEventMessage(payload, entries: &entries)
            case "response_item":
                parseResponseItem(payload, entries: &entries)
            default:
                continue
            }
        }

        if !entries.isEmpty {
            codexTranscriptLog.debug("Read \(entries.count) Codex entries")
        }

        return entries
    }

    /// Read session metadata from just the first few KB of a JSONL file.
    /// The session_meta line is always first, so no need to read the whole file.
    static func readSessionMetadata(from path: String) -> Metadata? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Only read the first 4KB — session_meta is always the first line
        let data = handle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String else {
                continue
            }

            return Metadata(sessionID: id, cwd: cwd, model: payload["model"] as? String)
        }

        return nil
    }

    private func parseEventMessage(_ payload: [String: Any], entries: inout [TranscriptEntry]) {
        let eventType = payload["type"] as? String ?? ""

        switch eventType {
        case "task_started":
            entries.append(.turnStarted)
        case "agent_message":
            if let message = payload["message"] as? String, !message.isEmpty {
                let phase = payload["phase"] as? String ?? ""
                if phase == "final_answer" {
                    entries.append(.response(message))
                } else {
                    entries.append(.reasoning(message))
                }
            }
        case "user_message":
            if let message = payload["message"] as? String, !message.isEmpty {
                entries.append(.userMessage(message))
            }
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any] else {
                return
            }
            totalInputTokens = (usage["input_tokens"] as? Int ?? totalInputTokens)
                + (usage["cached_input_tokens"] as? Int ?? 0)
            totalOutputTokens = usage["output_tokens"] as? Int ?? totalOutputTokens
            entries.append(.usage(input: totalInputTokens, output: totalOutputTokens))
        case "exec_command_end":
            guard let callID = payload["call_id"] as? String else { return }
            completedCallIDs.insert(callID)
            let command = payload["command"] as? [String] ?? []
            let shellCommand = shellCommandString(from: command)
            let output = payload["aggregated_output"] as? String
            let exitCode = payload["exit_code"] as? Int
            entries.append(.taskCompleted(TranscriptTaskEvent(
                id: callID,
                title: commandTitle(shellCommand, requiresApproval: false),
                detail: completionDetail(output: output, exitCode: exitCode),
                toolName: "exec_command",
                filePath: nil,
                bashCommand: shellCommand,
                isWriteOperation: commandLooksWriteOperation(shellCommand)
            )))
        case "task_complete":
            entries.append(.waitingForInput)
        default:
            break
        }
    }

    private func parseResponseItem(_ payload: [String: Any], entries: inout [TranscriptEntry]) {
        let payloadType = payload["type"] as? String ?? ""

        switch payloadType {
        case "message":
            guard let role = payload["role"] as? String,
                  let content = payload["content"] as? [[String: Any]] else {
                return
            }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            if role == "assistant" {
                entries.append(.response(text))
            } else if role == "user" {
                entries.append(.userMessage(text))
            }
        case "function_call":
            guard let callID = payload["call_id"] as? String,
                  let name = payload["name"] as? String else {
                return
            }
            let arguments = decodeJSONObject(from: payload["arguments"] as? String)
            let task = taskEvent(callID: callID, name: name, arguments: arguments)
            entries.append(.taskStarted(task))
        case "function_call_output":
            guard let callID = payload["call_id"] as? String,
                  !completedCallIDs.contains(callID) else {
                return
            }
            let output = payload["output"] as? String
            entries.append(.taskCompleted(TranscriptTaskEvent(
                id: callID,
                title: "Tool output",
                detail: compactOutput(output),
                toolName: nil,
                filePath: nil,
                bashCommand: nil,
                isWriteOperation: false
            )))
        case "custom_tool_call":
            guard let callID = payload["call_id"] as? String,
                  let name = payload["name"] as? String else {
                return
            }
            let arguments = decodeJSONObject(from: payload["input"] as? String)
            let task = taskEvent(callID: callID, name: name, arguments: arguments)
            entries.append(.taskStarted(task))
            if (payload["status"] as? String) == "completed" {
                completedCallIDs.insert(callID)
                entries.append(.taskCompleted(task))
            }
        case "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String else { return }
            completedCallIDs.insert(callID)
        case "local_shell_call":
            let callID = payload["call_id"] as? String ?? UUID().uuidString
            let command = payload["command"] as? String ?? ""
            entries.append(.taskStarted(TranscriptTaskEvent(
                id: callID,
                title: commandTitle(command, requiresApproval: false),
                detail: nil,
                toolName: "local_shell_call",
                filePath: nil,
                bashCommand: command,
                isWriteOperation: commandLooksWriteOperation(command)
            )))
        default:
            break
        }
    }

    private func taskEvent(callID: String, name: String, arguments: [String: Any]) -> TranscriptTaskEvent {
        switch name {
        case "exec_command":
            let command = arguments["cmd"] as? String ?? arguments["command"] as? String ?? ""
            let requiresApproval = (arguments["sandbox_permissions"] as? String) == "require_escalated"
            return TranscriptTaskEvent(
                id: callID,
                title: commandTitle(command, requiresApproval: requiresApproval),
                detail: requiresApproval ? "Codex requested escalated permissions for this command." : nil,
                toolName: name,
                filePath: nil,
                bashCommand: command,
                isWriteOperation: commandLooksWriteOperation(command)
            )
        case "apply_patch":
            return TranscriptTaskEvent(
                id: callID,
                title: "Apply patch",
                detail: "Updating local files",
                toolName: name,
                filePath: nil,
                bashCommand: nil,
                isWriteOperation: true
            )
        case "write_stdin":
            return TranscriptTaskEvent(
                id: callID,
                title: "Write to terminal",
                detail: nil,
                toolName: name,
                filePath: nil,
                bashCommand: nil,
                isWriteOperation: false
            )
        case "view_image":
            return TranscriptTaskEvent(
                id: callID,
                title: "View image",
                detail: arguments["path"] as? String,
                toolName: name,
                filePath: arguments["path"] as? String,
                bashCommand: nil,
                isWriteOperation: false
            )
        default:
            return TranscriptTaskEvent(
                id: callID,
                title: friendlyTitle(for: name, arguments: arguments),
                detail: nil,
                toolName: name,
                filePath: arguments["path"] as? String,
                bashCommand: arguments["command"] as? String,
                isWriteOperation: toolLooksWriteOperation(name)
            )
        }
    }

    private func decodeJSONObject(from text: String?) -> [String: Any] {
        guard let text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func compactOutput(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.prefix(3).joined(separator: " | ").prefix(180))
    }

    private func completionDetail(output: String?, exitCode: Int?) -> String? {
        var fragments: [String] = []
        if let exitCode {
            fragments.append(exitCode == 0 ? "exit 0" : "exit \(exitCode)")
        }
        if let output = compactOutput(output) {
            fragments.append(output)
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: " • ")
    }

    private func shellCommandString(from command: [String]) -> String {
        if command.count >= 3, (command[0].hasSuffix("zsh") || command[0].hasSuffix("bash")) {
            return command[2]
        }
        return command.joined(separator: " ")
    }

    private func commandTitle(_ command: String, requiresApproval: Bool) -> String {
        let short = String(command.trimmingCharacters(in: .whitespacesAndNewlines).prefix(72))
        if requiresApproval {
            return "Request approval: \(short)"
        }
        return short.isEmpty ? "Run command" : "Run: \(short)"
    }

    private func friendlyTitle(for name: String, arguments: [String: Any]) -> String {
        switch name {
        case "open":
            return "Open resource"
        case "search_query":
            return "Search web"
        case "read_mcp_resource":
            return "Read resource"
        case "list_mcp_resources":
            return "List MCP resources"
        default:
            if let path = arguments["path"] as? String {
                return "\(name): \(path)"
            }
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func commandLooksWriteOperation(_ command: String) -> Bool {
        let lower = command.lowercased()
        let patterns = ["apply_patch", "rm ", "mv ", "cp ", "mkdir ", "touch ", "chmod ", "git apply", "swift build", "npm install", "cargo build"]
        return patterns.contains(where: { lower.contains($0) })
    }

    private func toolLooksWriteOperation(_ name: String) -> Bool {
        ["apply_patch", "create_file", "update_file", "exec_command"].contains(name)
    }
}
