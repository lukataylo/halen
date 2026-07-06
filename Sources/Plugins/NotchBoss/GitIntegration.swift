import Foundation
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "git")

struct GitIntegration {

    static func fetchStatus(for session: ClaudeSession) {
        let cwd = session.projectPath
        DispatchQueue.global(qos: .utility).async {
            let branch = Shell.run("/usr/bin/git", ["branch", "--show-current"], cwd: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = Shell.run("/usr/bin/git", ["status", "--porcelain"], cwd: cwd)
            let changedFiles = status?.components(separatedBy: "\n").filter { !$0.isEmpty }.count ?? 0

            DispatchQueue.main.async {
                var changed = false
                if let b = branch, !b.isEmpty, session.gitBranch != b {
                    session.gitBranch = b
                    changed = true
                }
                if session.gitChangedFiles != changedFiles {
                    session.gitChangedFiles = changedFiles
                    changed = true
                }
                if changed { session.objectWillChange.send() }
            }
        }
    }

    static func fetchDiff(filePath: String, cwd: String) -> [DiffFile] {
        if let output = Shell.run("/usr/bin/git", ["diff", "--", filePath], cwd: cwd), !output.isEmpty {
            return parseDiff(output)
        }
        if let staged = Shell.run("/usr/bin/git", ["diff", "--cached", "--", filePath], cwd: cwd), !staged.isEmpty {
            return parseDiff(staged)
        }
        return []
    }

    static func parseDiff(_ rawDiff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var currentFile: String?
        var currentLines: [DiffLine] = []
        var oldLine = 0, newLine = 0

        for line in rawDiff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git") {
                if let f = currentFile { files.append(DiffFile(filename: f, lines: currentLines)) }
                currentLines = []
                let parts = line.split(separator: " ")
                currentFile = parts.last.map { String($0).replacingOccurrences(of: "b/", with: "", options: .anchored) } ?? "file"
            } else if line.hasPrefix("@@") {
                currentLines.append(DiffLine(kind: .hunkHeader, content: line, oldLineNum: nil, newLineNum: nil))
                // Parse: @@ -OLD,COUNT +NEW,COUNT @@
                if let match = line.range(of: #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#, options: .regularExpression) {
                    let hunk = String(line[match])
                    let digits = hunk.components(separatedBy: " ").compactMap { part -> Int? in
                        let stripped = part.trimmingCharacters(in: CharacterSet(charactersIn: "-+@, "))
                        return stripped.split(separator: ",").first.flatMap { Int($0) }
                    }
                    oldLine = digits.count > 0 ? digits[0] : 0
                    newLine = digits.count > 1 ? digits[1] : 0
                } else { oldLine = 0; newLine = 0 }
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                currentLines.append(DiffLine(kind: .addition, content: String(line.dropFirst()), oldLineNum: nil, newLineNum: newLine))
                newLine += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                currentLines.append(DiffLine(kind: .deletion, content: String(line.dropFirst()), oldLineNum: oldLine, newLineNum: nil))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                currentLines.append(DiffLine(kind: .context, content: String(line.dropFirst()), oldLineNum: oldLine, newLineNum: newLine))
                oldLine += 1; newLine += 1
            }
        }

        if let f = currentFile { files.append(DiffFile(filename: f, lines: currentLines)) }
        return files
    }
}
