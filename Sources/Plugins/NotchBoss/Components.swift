import SwiftUI

// MARK: - Progress Ring

struct ProgressRing: View {
    var progress: Double
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var color: Color = .orange

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Diff Views

struct DiffLineView: View {
    let line: DiffLine
    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLineNum.map(String.init) ?? "").frame(width: 26, alignment: .trailing).foregroundColor(.white.opacity(0.25))
            Text(line.newLineNum.map(String.init) ?? "").frame(width: 26, alignment: .trailing).foregroundColor(.white.opacity(0.25))
            Text(gutter).frame(width: 14, alignment: .center).foregroundColor(gutterColor)
            Text(line.content).foregroundColor(textColor).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.matrixMono(10))
        .padding(.vertical, 1).padding(.trailing, 6)
        .background(bgColor)
    }
    var gutter: String { switch line.kind { case .addition: return "+"; case .deletion: return "-"; case .hunkHeader: return "@@"; case .context: return " " } }
    var gutterColor: Color { switch line.kind { case .addition: return diffGreenText; case .deletion: return diffRedText; case .hunkHeader: return .cyan.opacity(0.6); case .context: return .clear } }
    var textColor: Color { switch line.kind { case .addition: return diffGreenText; case .deletion: return diffRedText; case .hunkHeader: return .cyan.opacity(0.4); case .context: return .white.opacity(0.65) } }
    var bgColor: Color { switch line.kind { case .addition: return diffGreenBg; case .deletion: return diffRedBg; case .hunkHeader: return Color.cyan.opacity(0.04); case .context: return .clear } }
}

struct DiffContentView: View {
    let files: [DiffFile]
    @State private var selected: Int = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(files.enumerated()), id: \.1.id) { idx, file in
                        Button { selected = idx } label: {
                            HStack(spacing: 4) {
                                Text(file.filename).font(.matrix(10, weight: .medium))
                                Text("+\(file.additions) -\(file.deletions)").font(.matrixMono(8)).foregroundColor(.white.opacity(0.4))
                            }
                            .foregroundColor(idx == selected ? .white : .white.opacity(0.45))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(idx == selected ? Color.white.opacity(0.08) : Color.clear)
                            .cornerRadius(4)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            Divider().background(Color.white.opacity(0.05))
            if files.indices.contains(selected) {
                ScrollView { VStack(spacing: 0) { ForEach(files[selected].lines) { DiffLineView(line: $0) } } }
                    .frame(maxHeight: 170)
            }
        }
        .background(Color.black.opacity(0.25)).cornerRadius(6)
    }
}

// MARK: - Session Picker

struct SessionPicker: View {
    @ObservedObject var state: NotchState
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(state.sessions.enumerated()), id: \.1.id) { idx, session in
                Button { state.activeSessionIndex = idx } label: {
                    HStack(spacing: 4) {
                        Circle().fill(dotColor(session)).frame(width: 5, height: 5)
                        Text(session.name).font(.matrix(10, weight: idx == state.activeSessionIndex ? .semibold : .regular)).lineLimit(1)
                    }
                    .foregroundColor(idx == state.activeSessionIndex ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(idx == state.activeSessionIndex ? Color.white.opacity(0.08) : Color.clear)
                    .cornerRadius(10)
                }.buttonStyle(.plain)
            }
        }
    }
    func dotColor(_ s: ClaudeSession) -> Color {
        s.sessionState.stateColor
    }
}

func progressColor(_ s: ClaudeSession) -> Color {
    s.sessionState.stateColor
}

func contextColor(for usage: Double) -> Color {
    if usage < 0.6 { return brandSuccess }
    if usage < 0.8 { return .orange }
    return .red
}

func ringProgress(for session: ClaudeSession) -> Double {
    // Completed/idle always show definitive state
    if session.isCompleted { return 1.0 }
    if session.sessionState == .idle { return 0.0 }

    if AppSettings.shared.showContextWindow {
        return session.contextUsage
    }
    // Activity mode: state-driven
    switch session.sessionState {
    case .running:        return 0.3
    case .waitingForUser: return 0.3
    case .needsApproval:  return 0.3
    default:              return 0.0
    }
}

func ringColor(for session: ClaudeSession) -> Color {
    // Completed sessions always show green
    if session.isCompleted { return SessionState.completed.stateColor }
    // Idle sessions always show gray
    if session.sessionState == .idle { return SessionState.idle.stateColor }

    if AppSettings.shared.showContextWindow {
        return contextColor(for: session.contextUsage)
    }
    return session.sessionState.stateColor
}

// MARK: - Color Rail

struct ColorRail: View {
    let sessions: [ClaudeSession]
    let expandedIndex: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let segmentHeight = max(12, (geo.size.height - CGFloat(max(0, sessions.count - 1))) / CGFloat(max(1, sessions.count)))
            VStack(spacing: 1) {
                ForEach(Array(sessions.enumerated()), id: \.1.id) { idx, session in
                    let state = session.sessionState
                    let isPulsing = state == .waitingForUser || state == .needsApproval
                    RoundedRectangle(cornerRadius: 2)
                        .fill(state.stateColor)
                        .overlay(alignment: .trailing) {
                            if idx == expandedIndex {
                                Rectangle()
                                    .fill(Color.white.opacity(0.8))
                                    .frame(width: 1)
                            }
                        }
                        .frame(height: segmentHeight)
                        .modifier(PulseOpacity(active: isPulsing))
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { onSelect(idx) }
                        .help(session.name + ": " + state.label)
                }
            }
        }
        .frame(width: 4)
    }
}

private struct PulseOpacity: ViewModifier {
    let active: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(active && pulsing ? 0.4 : 1.0)
            .animation(active ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: pulsing)
            .onAppear { if active { pulsing = true } }
            .onChange(of: active) { newVal in pulsing = newVal }
    }
}

// MARK: - Dot Progress

struct DotProgress: View {
    let completed: Int
    let running: Int
    let total: Int

    private let maxDots = 5
    private let dotSize: CGFloat = 4
    private let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            let displayTotal = min(total, maxDots)
            let scale = total > maxDots ? Double(total) / Double(maxDots) : 1.0
            let scaledCompleted = total > maxDots ? Int((Double(completed) / scale).rounded()) : completed
            let scaledRunning = total > maxDots ? max(running > 0 ? 1 : 0, Int((Double(running) / scale).rounded())) : running

            ForEach(0..<displayTotal, id: \.self) { i in
                if i < scaledCompleted {
                    Circle().fill(SessionState.completed.stateColor).frame(width: dotSize, height: dotSize)
                } else if i < scaledCompleted + scaledRunning {
                    Circle().fill(SessionState.running.stateColor).frame(width: dotSize, height: dotSize)
                } else {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 1).frame(width: dotSize, height: dotSize)
                }
            }
        }
    }
}

// MARK: - Session State Icon

struct SessionStateIcon: View {
    let state: SessionState
    var size: CGFloat = 14

    @State private var rotating = false
    @State private var pulsing = false
    @State private var scaling = false

    var body: some View {
        Image(systemName: state.icon)
            .font(.system(size: size))
            .foregroundColor(state.stateColor)
            .rotationEffect(state == .running ? .degrees(rotating ? 360 : 0) : .zero)
            .opacity(state == .waitingForUser ? (pulsing ? 0.4 : 1.0) : 1.0)
            .scaleEffect(state == .needsApproval ? (scaling ? 1.1 : 0.9) : 1.0)
            .frame(width: size, height: size)
            .onAppear { startAnimations() }
            .onChange(of: state) { _ in startAnimations() }
    }

    private func startAnimations() {
        switch state {
        case .running:
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) { rotating = true }
        case .waitingForUser:
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulsing = true }
        case .needsApproval:
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { scaling = true }
        default:
            rotating = false; pulsing = false; scaling = false
        }
    }
}
