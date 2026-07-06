import SwiftUI

// MARK: - Collapsed View

struct CollapsedView: View {
    @ObservedObject var state: NotchState
    let hasNotch: Bool

    var body: some View {
        HStack(spacing: 0) {
            ActiveProviderIcon(session: state.activeSession)
                .frame(width: hasNotch ? 18 : 16, height: hasNotch ? 18 : 16)
                .fixedSize()
                .padding(.leading, hasNotch ? 20 : 14)

            Spacer(minLength: 8)

            if state.hasActiveWork, let session = state.activeSession {
                if session.pendingApproval != nil {
                    Text("Approve?")
                        .font(.matrix(10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(brandOrange)
                        .cornerRadius(4)
                } else if session.isWaitingForUser {
                    Text("Waiting for you")
                        .font(.matrix(10, weight: .semibold))
                        .foregroundColor(brandOrange).lineLimit(1)
                } else if session.isCompleted {
                    Text("Completed" + (AppSettings.shared.showCostTracking ? " \(session.costSummary)" : ""))
                        .font(.matrix(10, weight: .medium))
                        .foregroundColor(brandSuccess).lineLimit(1)
                } else if session.isStale {
                    Text("Idle \(session.staleDuration)")
                        .font(.matrix(10, weight: .medium))
                        .foregroundColor(.white.opacity(0.35)).lineLimit(1)
                } else {
                    Text(AppSettings.shared.showTimeline ? session.statusMessage : session.sessionState.label)
                        .font(.matrix(10, weight: .medium))
                        .foregroundColor(.white.opacity(0.65)).lineLimit(1)
                }

                if state.sessions.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(Array(state.sessions.enumerated()), id: \.1.id) { idx, s in
                            let isActive = idx == state.activeSessionIndex
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(s.sessionState.stateColor.opacity(isActive ? 1.0 : 0.45))
                                .frame(width: isActive ? 10 : 6, height: 3)
                        }
                    }.padding(.leading, 4)
                }

                Spacer(minLength: 8)

                SessionStateIcon(state: session.sessionState, size: hasNotch ? 14 : 12)
                    .fixedSize()
                    .padding(.trailing, hasNotch ? 26 : 14)
            } else {
                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Expanded View

struct ExpandedViewV2: View {
    @ObservedObject var state: NotchState
    let hasNotch: Bool
    var onCollapse: () -> Void = {}

    /// The session with the most urgent pending approval, if any
    private var approvalSession: AgentSession? {
        state.sessions.first { !$0.pendingApprovals.isEmpty }
    }

    /// Bounds-safe session for the header icon
    private var headerSession: AgentSession? {
        guard !state.sessions.isEmpty else { return nil }
        let idx = state.resolvedExpandedIndex ?? state.mostUrgentIndex
        guard state.sessions.indices.contains(idx) else { return nil }
        return state.sessions[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider().background(Color.white.opacity(0.06))

            // Doorbell overlay takes over when approval is pending
            if let session = approvalSession, let approval = session.pendingApproval {
                ApprovalOverlay(
                    approval: approval,
                    session: session,
                    queueCount: state.sessions.reduce(0) { $0 + $1.pendingApprovals.count },
                    onDeny: {
                        ProviderManager.shared?.reject(requestId: approval.requestId, session: session)
                        collapseIfNoMoreApprovals()
                    },
                    onAllowOnce: {
                        ProviderManager.shared?.approve(requestId: approval.requestId, session: session)
                        collapseIfNoMoreApprovals()
                    },
                    onAllowAll: {
                        ProviderManager.shared?.allowAll(requestId: approval.requestId, toolName: approval.toolName, session: session)
                        collapseIfNoMoreApprovals()
                    },
                    onBypass: {
                        ProviderManager.shared?.bypass(requestId: approval.requestId, session: session)
                        collapseIfNoMoreApprovals()
                    },
                    onOpenTerminal: {
                        TerminalHelper.focusTerminal()
                    }
                )
            } else if state.sessions.isEmpty {
                EmptySessionView()
            } else {
                // Conflict banner (shown above cards when conflicts exist)
                ConflictBanner(coordination: CoordinationEngine.shared)

                // Normal card stack
                ScrollView(.vertical, showsIndicators: false) {
                    SessionCardStack(
                        state: state,
                        expandedIndex: state.resolvedExpandedIndex
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

            }
        }
    }

    // MARK: - Helpers

    /// Collapse the panel after an approval action if no more approvals are queued
    private func collapseIfNoMoreApprovals() {
        // Small delay so the approval removal is processed first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let remaining = state.sessions.reduce(0) { $0 + $1.pendingApprovals.count }
            if remaining == 0 { onCollapse() }
        }
    }

    // MARK: - Header

    var headerSection: some View {
        HStack(spacing: 8) {
            Button(action: onCollapse) {
                ActiveProviderIcon(session: headerSession)
                    .frame(width: 20, height: 20)
            }.buttonStyle(.plain)

            Spacer()

            if state.sessions.count > 1 {
                Text("\(state.sessions.count) sessions")
                    .font(.matrixMono(9, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }

            NewSessionHeaderButton()

            Button(action: onCollapse) {
                MatrixDotsChevronUp()
                    .fill(.white.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { onCollapse() }
        .padding(.horizontal, 16).padding(.top, hasNotch ? 12 : 10).padding(.bottom, 6)
    }
}

// MARK: - Root Notch View

struct NotchView: View {
    @ObservedObject var state: NotchState
    let screenID: CGDirectDisplayID
    let hasNotch: Bool

    @State private var isHovering = false
    @State private var showExpanded = false

    var isExpanded: Bool { state.expandedScreenID == screenID }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if showExpanded {
                    ExpandedViewV2(state: state, hasNotch: hasNotch, onCollapse: { collapse() })
                        .frame(width: 390)
                        .frame(maxHeight: 520)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    CollapsedView(state: state, hasNotch: hasNotch)
                        .frame(height: hasNotch ? 38 : 28)
                        .frame(width: hasNotch ? 300 : (state.hasActiveWork ? 220 : 130))
                        .contentShape(Rectangle())
                        .onTapGesture { expand() }
                }
            }
            .clipShape(notchShape)
            .background(notchShape.fill(Color.black))
            .overlay(borderOverlay)
            .shadow(color: (hasNotch && !showExpanded) ? .clear : .black.opacity(0.3), radius: 5, y: 2)
            .animation(.easeInOut(duration: 0.25), value: showExpanded)
            .animation(.easeInOut(duration: 0.15), value: state.hasActiveWork)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { isHovering = $0 }
        .onChange(of: isExpanded) { expanded in
            withAnimation(.easeInOut(duration: expanded ? 0.25 : 0.2)) { showExpanded = expanded }
        }
    }

    var notchShape: NotchCollapsedShape {
        NotchCollapsedShape(bottomRadius: showExpanded ? 18 : (hasNotch ? 18 : 12))
    }

    @ViewBuilder var borderOverlay: some View {
        if hasNotch && !showExpanded { Color.clear }
        else { notchShape.stroke(isHovering ? brandOrange.opacity(0.2) : Color.white.opacity(0.04), lineWidth: 0.5) }
    }

    func expand() { state.expandedScreenID = screenID }
    func collapse() { state.expandedScreenID = nil }
}
