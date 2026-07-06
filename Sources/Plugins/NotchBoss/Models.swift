import AppKit
import SwiftUI
import Combine

// MARK: - Colors

let brandOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
let brandSuccess = Color.green
let codexBlue = Color(red: 0.35, green: 0.62, blue: 0.96)
let diffRedBg = Color(red: 0.35, green: 0.08, blue: 0.08)
let diffGreenBg = Color(red: 0.06, green: 0.25, blue: 0.06)
let diffRedText = Color(red: 1.0, green: 0.55, blue: 0.55)
let diffGreenText = Color(red: 0.55, green: 1.0, blue: 0.55)

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    // NotchBar also defined `hasNotch` here. Dropped: the host reports
    // per-screen notch state via `NotchScreenInfo.hasNotch` instead.
}

// MARK: - Models

struct DiffFile: Identifiable {
    let id = UUID()
    var filename: String
    var lines: [DiffLine]
    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}

struct DiffLine: Identifiable {
    let id = UUID()

    enum Kind {
        case addition
        case deletion
        case context
        case hunkHeader
    }

    let kind: Kind
    let content: String
    let oldLineNum: Int?
    let newLineNum: Int?
}

private let maxVisibleTasks = 12

struct TaskItem: Identifiable {
    let id = UUID()
    var title: String
    var status: TaskStatus
    var detail: String?
    var startedAt: Date = Date()
    var toolName: String?
    var filePath: String?
    var diffFiles: [DiffFile]?
    var isExpanded: Bool = false
    var parentAgentId: String?
    var requestId: String? = nil

    var elapsed: String {
        let seconds = Date().timeIntervalSince(startedAt)
        return seconds < 60 ? String(format: "%.1fs", seconds) : String(format: "%.0fm", seconds / 60)
    }

    var isAgentTask: Bool { toolName == "Agent" }

    enum TaskStatus {
        case running
        case completed
        case pendingApproval
        case rejected

        var label: String {
            switch self {
            case .running: return "Running"
            case .completed: return "Done"
            case .pendingApproval: return "Approve?"
            case .rejected: return "Rejected"
            }
        }

        var color: Color {
            switch self {
            case .running: return .orange
            case .completed: return brandSuccess
            case .pendingApproval: return brandOrange
            case .rejected: return .red
            }
        }

        var icon: String {
            switch self {
            case .running: return "circle.dotted"
            case .completed: return "checkmark.circle.fill"
            case .pendingApproval: return "exclamationmark.shield.fill"
            case .rejected: return "xmark.circle.fill"
            }
        }
    }
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let requestId: String
    let toolName: String
    let toolDescription: String
    let filePath: String?
    let bashCommand: String?
    let isWriteOperation: Bool
    let timestamp: Date = Date()
    var diffFiles: [DiffFile]?

    // Content preview for the doorbell overlay
    var fileContent: String?     // For Write: the content being written
    var editOldString: String?   // For Edit: the string being replaced
    var editNewString: String?   // For Edit: the replacement string

    // Interactive tool data (AskUserQuestion)
    var interactiveQuestions: [InteractiveQuestion]?
}

struct InteractiveQuestion {
    let question: String
    let header: String?
    let options: [InteractiveOption]
    let multiSelect: Bool
}

struct InteractiveOption {
    let label: String
    let description: String
    let preview: String?
}

enum SessionState: Int, Comparable {
    case idle = 0
    case completed = 1
    case running = 2
    case waitingForUser = 3
    case needsApproval = 4

    static func < (lhs: SessionState, rhs: SessionState) -> Bool { lhs.rawValue < rhs.rawValue }

    var stateColor: Color {
        switch self {
        case .running:        return Color(red: 1.0, green: 0.65, blue: 0.0)
        case .waitingForUser: return Color(red: 1.0, green: 0.85, blue: 0.0)
        case .needsApproval:  return brandOrange
        case .completed:      return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .idle:           return Color(red: 0.4, green: 0.4, blue: 0.4)
        }
    }

    var icon: String {
        switch self {
        case .running:        return "circle.dotted"
        case .waitingForUser: return "questionmark.circle.fill"
        case .needsApproval:  return "exclamationmark.shield.fill"
        case .completed:      return "checkmark.circle.fill"
        case .idle:           return "moon.zzz"
        }
    }

    var label: String {
        switch self {
        case .running:        return "Running"
        case .waitingForUser: return "Waiting"
        case .needsApproval:  return "Approve?"
        case .completed:      return "Done"
        case .idle:           return "Idle"
        }
    }
}

// MARK: - Cost Estimation

struct ModelPricing {
    let inputPerMillion: Double
    let outputPerMillion: Double

    static let claudePricing: [String: ModelPricing] = [
        "claude-opus-4-6":   ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "claude-sonnet-4-6": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-haiku-4-5":  ModelPricing(inputPerMillion: 0.80, outputPerMillion: 4.0),
        "claude-sonnet-4-5": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-opus-4-5":   ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
    ]

    static let openAIPricing: [String: ModelPricing] = [
        "gpt-5.4":       ModelPricing(inputPerMillion: 5.0, outputPerMillion: 15.0),
        "gpt-5.4-mini":  ModelPricing(inputPerMillion: 0.8, outputPerMillion: 2.4),
        "gpt-5.3-codex": ModelPricing(inputPerMillion: 1.5, outputPerMillion: 6.0),
        "gpt-5.2":       ModelPricing(inputPerMillion: 2.0, outputPerMillion: 8.0),
    ]

    /// All known pricing across providers. Keyed by model substring.
    static let allPricing: [String: ModelPricing] = {
        var combined: [String: ModelPricing] = [:]
        for (k, v) in claudePricing { combined[k] = v }
        for (k, v) in openAIPricing { combined[k] = v }
        return combined
    }()

    static func estimate(provider: ProviderID, model: String?, inputTokens: Int, outputTokens: Int) -> Double {
        let key = allPricing.keys.first { model?.localizedCaseInsensitiveContains($0) == true }
        guard let selected = key.flatMap({ allPricing[$0] }) else { return 0 }
        return (Double(inputTokens) / 1_000_000 * selected.inputPerMillion)
            + (Double(outputTokens) / 1_000_000 * selected.outputPerMillion)
    }
}

class AgentSession: Identifiable, ObservableObject {
    let id = UUID()
    let providerID: ProviderID

    @Published var name: String
    @Published var projectPath: String
    @Published var progress: Double = 0
    @Published var tasks: [TaskItem] = []
    @Published var statusMessage: String = "Idle"
    @Published var isActive: Bool = false
    @Published var isCompleted: Bool = false
    @Published var lastResponse: String? = nil
    @Published var lastReasoning: String? = nil
    @Published var inputTokens: Int = 0
    @Published var outputTokens: Int = 0
    @Published var isWaitingForUser: Bool = false
    @Published var transcriptPath: String? = nil
    @Published var permissionMode: String? = nil
    @Published var modelName: String? = nil
    @Published var instructionsContent: String? = nil
    @Published var estimatedCost: Double = 0
    @Published var gitBranch: String? = nil
    @Published var gitChangedFiles: Int = 0
    @Published var pendingApprovals: [PendingApproval] = []

    /// The next approval that needs attention (first in queue)
    var pendingApproval: PendingApproval? { pendingApprovals.first }
    @Published var terminalAvailable: Bool = false
    /// Holds the embedded SwiftTerm terminal view when this session was launched via PTY.
    var embeddedTerminalView: NSView? = nil
    @Published var isPinned: Bool = false
    @Published var autoApproveAll: Bool = false
    @Published var lastToolActivityAt: Date? = nil

    var transcriptReader: (any LiveTranscriptReader)? = nil
    var startedAt: Date = Date()
    var pid: Int32?

    init(name: String, projectPath: String, providerID: ProviderID) {
        self.name = name
        self.projectPath = projectPath
        self.providerID = providerID
    }

    var provider: ProviderDescriptor? { ProviderRegistry.shared.descriptor(for: providerID) }
    var providerDisplayName: String { provider?.displayName ?? providerID.rawValue }
    var providerShortName: String { provider?.shortName ?? providerID.rawValue }
    var providerAccentColor: Color { provider?.accentColor ?? .gray }
    var instructionsFileName: String { provider?.instructionsFileName ?? "INSTRUCTIONS.md" }

    var claudeMdContent: String? {
        get { instructionsContent }
        set { instructionsContent = newValue }
    }

    var tokenSummary: String {
        guard inputTokens > 0 else { return "" }
        return "\(formatTokens(inputTokens))in / \(formatTokens(outputTokens))out"
    }

    var costSummary: String {
        guard estimatedCost > 0 else { return "" }
        if estimatedCost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", estimatedCost)
    }

    var duration: String {
        let seconds = Date().timeIntervalSince(startedAt)
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    // MARK: - Context Window

    var contextWindowSize: Int {
        guard let model = modelName?.lowercased() else { return 200_000 }
        if model.contains("opus") && model.contains("4-6") { return 1_000_000 }
        return 200_000
    }

    var contextUsage: Double {
        let total = inputTokens + outputTokens
        guard total > 0 else { return 0 }
        return min(Double(total) / Double(contextWindowSize), 1.0)
    }

    var contextSummary: String {
        let total = inputTokens + outputTokens
        guard total > 0 else { return "" }
        // Cap display at window size — cumulative tokens can exceed the window after compaction
        let displayTotal = min(total, contextWindowSize)
        return "\(formatTokens(displayTotal)) / \(formatTokens(contextWindowSize))"
    }

    // MARK: - Stale Detection

    var isStale: Bool {
        guard isActive, !isCompleted else { return false }
        guard let lastActivity = lastToolActivityAt else { return false }
        return Date().timeIntervalSince(lastActivity) > 120
    }

    var staleDuration: String {
        guard let lastActivity = lastToolActivityAt else { return "" }
        let seconds = Date().timeIntervalSince(lastActivity)
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    var displayStatus: String {
        if isStale { return "Idle \(staleDuration)" }
        return statusMessage
    }

    func updateCost() {
        estimatedCost = ModelPricing.estimate(
            provider: providerID,
            model: modelName,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    var sessionState: SessionState {
        if !pendingApprovals.isEmpty { return .needsApproval }
        if isWaitingForUser { return .waitingForUser }
        if isActive && !isCompleted { return .running }
        if isCompleted { return .completed }
        return .idle
    }

    func appendTask(_ task: TaskItem) {
        if tasks.count >= maxVisibleTasks { tasks.removeFirst() }
        tasks.append(task)
        lastToolActivityAt = Date()
    }

    var completedTaskCount: Int { tasks.filter { $0.status == .completed }.count }
    var runningTaskCount: Int { tasks.filter { $0.status == .running }.count }
    var totalTaskCount: Int { tasks.count }
}

typealias ClaudeSession = AgentSession

class NotchState: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var activeSessionIndex: Int = 0
    @Published var expandedScreenID: CGDirectDisplayID? = nil
    @Published var expandedCardIndex: Int? = nil
    @Published var lastManualSelectTime: Date? = nil

    var activeSession: AgentSession? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        return sessions[activeSessionIndex]
    }

    var hasActiveWork: Bool { sessions.contains { $0.isActive } }

    var resolvedExpandedIndex: Int? {
        if let manual = expandedCardIndex, sessions.indices.contains(manual) {
            return manual
        }
        if let pinned = sessions.firstIndex(where: { $0.isPinned }) {
            return pinned
        }
        // Only auto-expand if a session needs approval
        if let urgent = sessions.firstIndex(where: { $0.sessionState == .needsApproval }) {
            return urgent
        }
        return nil
    }

    var mostUrgentIndex: Int {
        guard !sessions.isEmpty else { return 0 }
        return sessions.indices.max(by: { a, b in
            let sa = sessions[a].sessionState
            let sb = sessions[b].sessionState
            if sa != sb { return sa < sb }
            let ta = sessions[a].tasks.last?.startedAt ?? sessions[a].startedAt
            let tb = sessions[b].tasks.last?.startedAt ?? sessions[b].startedAt
            return ta < tb
        }) ?? 0
    }

    func selectCard(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        expandedCardIndex = index
        activeSessionIndex = index
        lastManualSelectTime = Date()
    }

    func removeSession(_ session: AgentSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: idx)
        normalizeSelectionAfterSessionMutation(removedIndices: [idx])
    }

    func removeSessions(for providerID: ProviderID) {
        let removedIndices = sessions.enumerated().compactMap { index, session in
            session.providerID == providerID ? index : nil
        }
        guard !removedIndices.isEmpty else { return }

        sessions.removeAll { $0.providerID == providerID }
        normalizeSelectionAfterSessionMutation(removedIndices: removedIndices)
    }

    private func normalizeSelectionAfterSessionMutation(removedIndices: [Int]) {
        if sessions.isEmpty {
            activeSessionIndex = 0
            expandedCardIndex = nil
        } else {
            activeSessionIndex = min(activeSessionIndex, sessions.count - 1)
            if let expanded = expandedCardIndex {
                if removedIndices.contains(expanded) {
                    expandedCardIndex = nil
                } else {
                    let removedBeforeExpanded = removedIndices.filter { $0 < expanded }.count
                    if removedBeforeExpanded > 0 {
                        expandedCardIndex = expanded - removedBeforeExpanded
                    }
                }
            }
        }
    }

    func reset() {
        sessions.removeAll()
        activeSessionIndex = 0
        expandedScreenID = nil
        expandedCardIndex = nil
    }
}
