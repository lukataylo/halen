import SwiftUI

// MARK: - Approval Doorbell Overlay

/// Full-panel overlay that appears when an approval is pending.
/// Shows file preview, command preview, and 4-level action buttons.
/// Inspired by the "doorbell" pattern — quiet until it needs you,
/// then shows exactly what needs deciding.
struct ApprovalOverlay: View {
    let approval: PendingApproval
    let session: AgentSession
    let queueCount: Int
    let onDeny: () -> Void
    let onAllowOnce: () -> Void
    let onAllowAll: () -> Void
    let onBypass: () -> Void
    var onOpenTerminal: (() -> Void)?

    private var isInteractive: Bool {
        ToolApprovalCategory.fromToolName(approval.toolName) == .interactive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Context header
            contextHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.06))

            // Tool badge + description
            toolBadge
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Content preview
            contentPreview
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            Divider().background(Color.white.opacity(0.06))

            // Action buttons
            actionButtons
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            // Queue indicator + session link
            footer
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Context Header

    private var contextHeader: some View {
        HStack(spacing: 8) {
            Text(session.name)
                .font(.matrix(13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            if let model = session.modelName {
                Text(shortModelName(model))
                    .font(.matrixMono(10, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            Text(approvalAge)
                .font(.matrixMono(10))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private var approvalAge: String {
        let seconds = Date().timeIntervalSince(approval.timestamp)
        if seconds < 60 { return "<1m" }
        return "\(Int(seconds / 60))m"
    }

    // MARK: - Tool Badge

    private var toolBadge: some View {
        HStack(spacing: 8) {
            // Warning icon + tool type
            HStack(spacing: 5) {
                Image(systemName: toolIcon)
                    .font(.matrix(10, weight: .bold))
                    .foregroundColor(toolColor)
                Text(approval.toolName)
                    .font(.matrix(12, weight: .bold))
                    .foregroundColor(toolColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(toolColor.opacity(0.15))
            .cornerRadius(5)

            // File path or description
            Text(approval.toolDescription)
                .font(.matrix(11))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)

            Spacer()
        }
    }

    private var toolIcon: String {
        if isInteractive { return "bubble.left.and.bubble.right.fill" }
        switch approval.toolName {
        case "Edit", "Write", "NotebookEdit": return "exclamationmark.triangle.fill"
        case "Bash": return "exclamationmark.triangle.fill"
        case "Agent": return "person.2.fill"
        case "Read", "Grep", "Glob": return "doc.text.magnifyingglass"
        default: return "questionmark.circle"
        }
    }

    private var toolColor: Color {
        if isInteractive { return .cyan }
        switch approval.toolName {
        case "Bash": return .red
        case "Edit", "Write", "NotebookEdit": return .orange
        case "Agent": return .purple
        default: return .yellow
        }
    }

    // MARK: - Content Preview

    @ViewBuilder
    private var contentPreview: some View {
        if let questions = approval.interactiveQuestions, !questions.isEmpty {
            // Interactive tool: show questions and options
            interactivePreview(questions: questions)
        } else if let content = approval.fileContent {
            // Write: show the file content being written
            filePreviewBox(
                filename: shortFilename(approval.filePath),
                badge: "new file",
                badgeColor: .green,
                lines: content.components(separatedBy: "\n")
            )
        } else if let oldStr = approval.editOldString, let newStr = approval.editNewString {
            // Edit: show old → new
            editPreviewBox(
                filename: shortFilename(approval.filePath),
                oldLines: oldStr.components(separatedBy: "\n"),
                newLines: newStr.components(separatedBy: "\n")
            )
        } else if let cmd = approval.bashCommand {
            // Bash: show the command
            commandPreviewBox(command: cmd)
        } else {
            // Fallback: just show the description
            Text(approval.toolDescription)
                .font(.matrixMono(11))
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.3))
                .cornerRadius(6)
        }
    }

    private func filePreviewBox(filename: String, badge: String, badgeColor: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack(spacing: 6) {
                Text(filename)
                    .font(.matrixMono(11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text(badge)
                    .font(.matrix(9, weight: .bold))
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeColor.opacity(0.2))
                    .cornerRadius(3)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.06))

            // Line-numbered content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(12).enumerated()), id: \.0) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(idx + 1)")
                                .font(.matrixMono(10))
                                .foregroundColor(.white.opacity(0.2))
                                .frame(width: 28, alignment: .trailing)
                                .padding(.trailing, 8)
                            Text(line)
                                .font(.matrixMono(10))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }
                    if lines.count > 12 {
                        Text("  ... \(lines.count - 12) more lines")
                            .font(.matrixMono(9))
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 150)
        }
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func editPreviewBox(filename: String, oldLines: [String], newLines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(filename)
                    .font(.matrixMono(11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("edit")
                    .font(.matrix(9, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(3)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.06))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(oldLines.prefix(6).enumerated()), id: \.0) { _, line in
                        HStack(spacing: 0) {
                            Text("-")
                                .frame(width: 14, alignment: .center)
                                .foregroundColor(diffRedText)
                            Text(line)
                                .foregroundColor(diffRedText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.matrixMono(10))
                        .padding(.vertical, 1)
                        .background(diffRedBg)
                    }
                    ForEach(Array(newLines.prefix(6).enumerated()), id: \.0) { _, line in
                        HStack(spacing: 0) {
                            Text("+")
                                .frame(width: 14, alignment: .center)
                                .foregroundColor(diffGreenText)
                            Text(line)
                                .foregroundColor(diffGreenText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.matrixMono(10))
                        .padding(.vertical, 1)
                        .background(diffGreenBg)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 140)
        }
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func commandPreviewBox(command: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("$")
                    .font(.matrixMono(11, weight: .bold))
                    .foregroundColor(.green.opacity(0.5))
                Text(command)
                    .font(.matrixMono(11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(5)
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Interactive Preview

    @State private var expandedPreviewIndex: Int?

    private func interactivePreview(questions: [InteractiveQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Text(questions.count > 1 ? "\(questions.count) Questions" : "Question")
                    .font(.matrixMono(11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("respond in terminal")
                    .font(.matrix(9, weight: .bold))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.cyan.opacity(0.2))
                    .cornerRadius(3)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.06))

            // Questions list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(questions.enumerated()), id: \.0) { qIdx, q in
                        VStack(alignment: .leading, spacing: 6) {
                            // Question header chip + select mode
                            HStack(spacing: 6) {
                                if let header = q.header {
                                    Text(header)
                                        .font(.matrix(9, weight: .bold))
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.cyan.opacity(0.15))
                                        .cornerRadius(3)
                                }
                                if q.multiSelect {
                                    Text("multi-select")
                                        .font(.matrix(8, weight: .medium))
                                        .foregroundColor(.white.opacity(0.3))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.06))
                                        .cornerRadius(2)
                                }
                                Spacer()
                            }

                            // Question text
                            Text(q.question)
                                .font(.matrixMono(11))
                                .foregroundColor(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)

                            // Options
                            ForEach(Array(q.options.enumerated()), id: \.0) { optIdx, opt in
                                let globalIdx = qIdx * 100 + optIdx
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(q.multiSelect ? "☐" : "○")
                                            .font(.matrixMono(10))
                                            .foregroundColor(.cyan.opacity(0.6))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(opt.label)
                                                .font(.matrixMono(10, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.7))
                                            if !opt.description.isEmpty {
                                                Text(opt.description)
                                                    .font(.matrixMono(9))
                                                    .foregroundColor(.white.opacity(0.4))
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        // Preview toggle
                                        if opt.preview != nil {
                                            Button {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    expandedPreviewIndex = expandedPreviewIndex == globalIdx ? nil : globalIdx
                                                }
                                            } label: {
                                                Image(systemName: expandedPreviewIndex == globalIdx ? "eye.slash" : "eye")
                                                    .font(.matrix(9))
                                                    .foregroundColor(.cyan.opacity(0.5))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    // Expanded preview
                                    if let preview = opt.preview, expandedPreviewIndex == globalIdx {
                                        Text(preview)
                                            .font(.matrixMono(9))
                                            .foregroundColor(.white.opacity(0.6))
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.black.opacity(0.4))
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.cyan.opacity(0.15), lineWidth: 0.5)
                                            )
                                            .padding(.leading, 16)
                                            .padding(.top, 3)
                                            .transition(.opacity)
                                    }
                                }
                            }

                            // Implicit "Other" option
                            HStack(spacing: 6) {
                                Text(q.multiSelect ? "☐" : "○")
                                    .font(.matrixMono(10))
                                    .foregroundColor(.white.opacity(0.25))
                                Text("Other (custom input)")
                                    .font(.matrixMono(9))
                                    .foregroundColor(.white.opacity(0.25))
                                    .italic()
                            }
                        }

                        // Separator between questions
                        if qIdx < questions.count - 1 {
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 220)
        }
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Action Buttons

    @State private var showAdvanced = false

    private var actionButtons: some View {
        VStack(spacing: 6) {
            if isInteractive {
                // Interactive tools: Deny + Open in Terminal
                HStack(spacing: 8) {
                    Button(action: onDeny) {
                        Text("Deny")
                            .font(.matrix(11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onAllowOnce()
                        onOpenTerminal?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.matrix(10))
                            Text("Open in Terminal")
                                .font(.matrix(11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.cyan.opacity(0.7))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Standard tools: Deny + Allow
                HStack(spacing: 8) {
                    Button(action: onDeny) {
                        Text("Deny")
                            .font(.matrix(11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onAllowOnce) {
                        Text("Allow")
                            .font(.matrix(11, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(brandOrange)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                // Disclosure chevron for advanced options
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Group {
                            if showAdvanced {
                                MatrixChevronUp()
                                    .stroke(.white.opacity(0.3), lineWidth: 1.5)
                            } else {
                                MatrixChevronDown()
                                    .stroke(.white.opacity(0.3), lineWidth: 1.5)
                            }
                        }
                        .frame(width: 8, height: 8)
                        Text("More options")
                            .font(.matrix(10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .buttonStyle(.plain)

                // Advanced options (revealed)
                if showAdvanced {
                    HStack(spacing: 8) {
                        Button(action: onAllowAll) {
                            Text("Allow All \(approval.toolName)")
                                .font(.matrix(10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Button(action: onBypass) {
                            Text("Auto-approve Session")
                                .font(.matrix(10, weight: .semibold))
                                .foregroundColor(.red.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.08))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if queueCount > 1 {
                Text("\(queueCount - 1) more pending")
                    .font(.matrix(10))
                    .foregroundColor(brandOrange.opacity(0.6))
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func shortFilename(_ path: String?) -> String {
        guard let path = path else { return "file" }
        let parts = path.split(separator: "/")
        return parts.count > 2 ? String(parts.suffix(2).joined(separator: "/")) : path
    }
}
