import SwiftUI

// MARK: - Session Card Stack

struct SessionCardStack: View {
    @ObservedObject var state: NotchState
    let expandedIndex: Int?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(state.sessions.enumerated()), id: \.1.id) { idx, session in
                if idx == expandedIndex {
                    SessionCardExpanded(session: session, state: state, onCollapse: {
                        // Collapsing returns to all-collapsed state
                        state.expandedCardIndex = nil
                    }, onClose: {
                        state.removeSession(session)
                    })
                } else {
                    SessionCardCollapsed(session: session, onTap: {
                        state.selectCard(idx)
                    }, onClose: {
                        state.removeSession(session)
                    })
                }
            }
        }
    }
}

// MARK: - Collapsed Card

struct SessionCardCollapsed: View {
    @ObservedObject var session: ClaudeSession
    let onTap: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var hovering = false
    @State private var closeHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Left: provider icon
            ProviderMiniIcon(session: session)
                .frame(width: 12, height: 12)

            // Name
            Text(session.name)
                .font(.matrix(11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Status text
            Text(statusText)
                .font(.matrixMono(10))
                .foregroundColor(statusColor)

            // Duration
            Text(session.duration)
                .font(.matrixMono(10))
                .foregroundColor(.white.opacity(0.25))

            if hovering, let onClose = onClose {
                Button(action: onClose) {
                    MatrixClose()
                        .stroke(closeHovering ? .white.opacity(0.8) : .white.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .frame(width: 16, height: 16)
                        .background(closeHovering ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovering = $0 }
            } else {
                MatrixChevronRight()
                    .stroke(.white.opacity(hovering ? 0.4 : 0.15), lineWidth: 1.5)
                    .frame(width: 6, height: 8)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering = $0 }
    }

    private var statusText: String {
        if session.isCompleted { return "Done" }
        if session.isStale { return "Idle" }
        if session.pendingApproval != nil { return "Approve?" }
        if session.isWaitingForUser { return "Waiting" }
        if AppSettings.shared.showContextWindow && session.contextUsage > 0 {
            return "\(Int(session.contextUsage * 100))%"
        }
        return session.sessionState.label
    }

    private var statusColor: Color {
        if session.isCompleted { return SessionState.completed.stateColor }
        if session.pendingApproval != nil { return brandOrange }
        return session.sessionState.stateColor
    }
}

// MARK: - Expanded Card

struct SessionCardExpanded: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject var state: NotchState
    var onCollapse: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var messageText: String = ""
    @State private var nameHovering: Bool = false

    private var compact: Bool { AppSettings.shared.compactMode }
    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader

            Divider().background(Color.white.opacity(0.06))

            // Git bar
            if settings.showGitStatus, session.gitBranch != nil {
                gitBar
            }

            // Content: embedded terminal or standard card view
            if session.embeddedTerminalView != nil {
                TerminalSessionView(sessionId: session.id)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 200, maxHeight: 360)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                // Scrollable content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Timeline
                        if settings.showTimeline, !session.tasks.isEmpty {
                            TimelineSpine(
                                tasks: settings.showDiffs ? session.tasks : session.tasks.map { var t = $0; t.diffFiles = nil; return t },
                                pendingApproval: nil,  // Doorbell handles approvals now
                                session: session
                            )
                            .padding(.horizontal, 8)
                        }

                        // Reasoning
                        if settings.showReasoning, let reasoning = session.lastReasoning {
                            reasoningSection(reasoning)
                        }

                        // Waiting indicator
                        if session.isWaitingForUser {
                            waitingIndicator
                        }
                    }
                }
            }

            Divider().background(Color.white.opacity(0.06))

            statsBar

            // Message input — hidden for embedded terminal sessions (user types directly in the terminal)
            if settings.showMessageInput && session.isActive && !session.isCompleted && session.terminalAvailable && session.embeddedTerminalView == nil {
                messageInput
            }
        }
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(session.sessionState.stateColor.opacity(0.2), lineWidth: 0.5)
        )
        .cornerRadius(10)
    }

    // MARK: - Card Header

    var cardHeader: some View {
        HStack(spacing: 8) {
            ProviderMiniIcon(session: session)
                .frame(width: 16, height: 16)

            HStack(spacing: 4) {
                Text(session.name)
                    .font(.matrix(13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { onCollapse() }

                if nameHovering || session.isPinned {
                    Button { session.isPinned.toggle() } label: {
                        MatrixPin()
                            .stroke(session.isPinned ? brandOrange : .white.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onHover { nameHovering = $0 }

            if session.isStale {
                Text("Idle \(session.staleDuration)")
                    .font(.matrix(9, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
            }

            Spacer()

            SessionStateIcon(state: session.sessionState, size: 14)

            if let onClose = onClose {
                Button(action: onClose) {
                    MatrixClose()
                        .stroke(.white.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if state.sessions.count > 1 {
                Button(action: onCollapse) {
                    MatrixDotsChevronDown()
                        .fill(.white.opacity(0.4))
                        .frame(width: 16, height: 16)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, compact ? 5 : 8)
    }

    // MARK: - Git Bar

    var gitBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundColor(.purple.opacity(0.6))
            Text(session.gitBranch ?? "")
                .font(.matrixMono(10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            if session.gitChangedFiles > 0 {
                Text("\(session.gitChangedFiles) changed")
                    .font(.matrixMono(9))
                    .foregroundColor(.orange.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color.purple.opacity(0.04))
    }

    // MARK: - Reasoning

    func reasoningSection(_ reasoning: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 9))
                .foregroundColor(brandOrange.opacity(0.6))
                .padding(.top, 2)
            Text(reasoning)
                .font(.matrix(11))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Waiting Indicator

    var waitingIndicator: some View {
        HStack(spacing: 6) {
            Circle().fill(SessionState.waitingForUser.stateColor).frame(width: 6, height: 6)
            Text("Claude is waiting for your input")
                .font(.matrix(11, weight: .medium))
                .foregroundColor(SessionState.waitingForUser.stateColor)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(SessionState.waitingForUser.stateColor.opacity(0.06))
    }

    // MARK: - Stats Bar

    var statsBar: some View {
        Group {
            if !session.tokenSummary.isEmpty {
                HStack(spacing: 12) {
                    if AppSettings.shared.showContextWindow {
                        Label(session.contextSummary, systemImage: "brain")
                            .foregroundColor(contextColor(for: session.contextUsage).opacity(0.6))
                    } else {
                        Label(session.tokenSummary, systemImage: "number")
                    }
                    if AppSettings.shared.showCostTracking && !session.costSummary.isEmpty {
                        Label(session.costSummary, systemImage: "dollarsign.circle")
                            .foregroundColor(brandOrange.opacity(0.5))
                    }
                    Label(session.duration, systemImage: "clock")
                    Spacer()
                }
                .font(.matrixMono(9))
                .foregroundColor(.white.opacity(0.25))
                .padding(.horizontal, 12).padding(.vertical, compact ? 2 : 4)
            }
        }
    }

    // MARK: - Message Input

    var messageInput: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
            ZStack(alignment: .leading) {
                if messageText.isEmpty {
                    Text(session.isWaitingForUser ? "Reply to \(session.providerShortName)..." : "Message \(session.providerShortName)...")
                        .font(.matrix(12))
                        .foregroundColor(.white.opacity(0.3))
                }
                TextField("", text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.matrix(12))
                    .foregroundColor(.white)
                    .onSubmit { send() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(session.isWaitingForUser ? SessionState.waitingForUser.stateColor.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
    }

    func send() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalHelper.sendInput(text, processName: "claude")
        }
    }

}

// MARK: - Empty State

struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            NotchBarIcon()
                .opacity(0.3)
                .frame(width: 32, height: 32)
            Text("No active sessions")
                .font(.matrix(13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            Text("Start your agent in the terminal")
                .font(.matrix(11))
                .foregroundColor(.white.opacity(0.25))

            NewSessionButton()
                .padding(.top, 4)

            Text("⌘⇧C to toggle")
                .font(.matrixMono(9, weight: .medium))
                .foregroundColor(.white.opacity(0.15))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - New Session Button

struct NewSessionButton: View {
    @State private var hovering = false

    private let terminalGreen = Color(red: 0.4, green: 0.85, blue: 0.65)

    var body: some View {
        Button {
            pickFolderAndLaunch()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                Text("New Session")
                    .font(.matrix(11, weight: .semibold))
            }
            .foregroundColor(hovering ? .white : terminalGreen)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? terminalGreen.opacity(0.3) : terminalGreen.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(terminalGreen.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func pickFolderAndLaunch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project directory for the Claude Code session"
        panel.prompt = "Launch Session"
        panel.level = .modalPanel

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let provider = ProviderManager.shared?.controller(for: .embeddedTerminal) as? EmbeddedTerminalProvider {
                provider.launchSession(cwd: url.path)
            }
        }
    }
}

// MARK: - New Session Header Button (compact "+" for the expanded header)

struct NewSessionHeaderButton: View {
    @State private var hovering = false

    var body: some View {
        Button {
            pickFolderAndLaunch()
        } label: {
            MatrixPlus()
                .stroke(hovering ? .white.opacity(0.7) : .white.opacity(0.3), lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .frame(width: 22, height: 22)
                .background(hovering ? Color.white.opacity(0.1) : Color.clear)
                .cornerRadius(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Launch new Claude Code session")
    }

    private func pickFolderAndLaunch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project directory for the Claude Code session"
        panel.prompt = "Launch Session"
        panel.level = .modalPanel

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let provider = ProviderManager.shared?.controller(for: .embeddedTerminal) as? EmbeddedTerminalProvider {
                provider.launchSession(cwd: url.path)
            }
        }
    }
}

// MARK: - Shared Helpers

func shortModelName(_ model: String) -> String {
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    return String(model.prefix(20))
}
