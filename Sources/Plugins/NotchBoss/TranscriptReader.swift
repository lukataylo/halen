import Foundation
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "transcript")

/// Reads and tails Claude Code transcript .jsonl files to extract
/// Claude's reasoning, token usage, and session state.
class TranscriptReader: LiveTranscriptReader {
    let path: String
    var lastOffset: UInt64 = 0
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var partialLine: String = ""  // Buffer for incomplete lines at end of read

    init(path: String) {
        self.path = path
        log.info("TranscriptReader init for \(path)")
        // Start from the end of the file so we only read new entries
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            // Read last 10KB on init to get recent context
            lastOffset = size > 10000 ? size - 10000 : 0
            log.debug("Starting at offset \(self.lastOffset) (file size: \(size))")
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
            guard let message = json["message"] as? [String: Any] else { continue }

            if type == "assistant" {
                // Extract model name
                if let model = message["model"] as? String, !model.isEmpty {
                    log.debug("Detected model: \(model)")
                    entries.append(.modelInfo(model))
                }

                // Extract text blocks (Claude's reasoning)
                if let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String, !text.isEmpty {
                            entries.append(.reasoning(text))
                        }
                    }
                }

                // Extract token usage
                if let usage = message["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int ?? 0)
                        + (usage["cache_read_input_tokens"] as? Int ?? 0)
                        + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    let output = usage["output_tokens"] as? Int ?? 0
                    totalInputTokens += input
                    totalOutputTokens += output
                    entries.append(.usage(input: totalInputTokens, output: totalOutputTokens))
                    log.debug("Token usage: \(self.totalInputTokens) in / \(self.totalOutputTokens) out")
                }
            } else if type == "user" {
                // Check if Claude is waiting for user input (no toolUseResult means user typed)
                if json["toolUseResult"] == nil, let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String, !text.isEmpty {
                            entries.append(.userMessage(text))
                        }
                    }
                }
            }
        }

        if !entries.isEmpty {
            log.debug("Read \(entries.count) transcript entries")
        }
        return entries
    }
}

enum TranscriptEntry {
    case reasoning(String)
    case usage(input: Int, output: Int)
    case userMessage(String)
    case modelInfo(String)
    case status(String)
    case response(String)
    case turnStarted
    case waitingForInput
    case taskStarted(TranscriptTaskEvent)
    case taskCompleted(TranscriptTaskEvent)
    case sessionCompleted
}

struct TranscriptTaskEvent {
    let id: String
    let title: String
    let detail: String?
    let toolName: String?
    let filePath: String?
    let bashCommand: String?
    let isWriteOperation: Bool
}

/// Format token count to human-readable (e.g. "12.5k", "1.2M")
func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}
