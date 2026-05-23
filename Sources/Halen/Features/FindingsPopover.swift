import SwiftUI

/// One actionable item in a `FindingsPopover` — a tone match, a clarity issue,
/// a style-rule violation. `onFix` is the per-item one-tap action; `nil` when
/// the finding is informational only.
struct Finding: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let colorName: String
    let fixLabel: String?
    let onFix: (() -> Void)?

    init(id: String = UUID().uuidString,
         title: String,
         detail: String? = nil,
         colorName: String = "blue",
         fixLabel: String? = nil,
         onFix: (() -> Void)? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.colorName = colorName
        self.fixLabel = fixLabel
        self.onFix = onFix
    }
}

/// Live state for an in-popover streaming rewrite. Plugins that wire a
/// `StreamingRewriteState` into `FindingsPopover` flip the popover from its
/// idle layout (findings + primary action) into a streaming layout where
/// tokens land in a preview pane as the local model writes them.
///
/// `ObservableObject` (not `@Observable`) on purpose: the modern macro chain
/// fails to re-render text inside an `NSHostingView`-backed `NSPanel`, while
/// `@Published` + `@ObservedObject` is reliable there.
@MainActor
final class StreamingRewriteState: ObservableObject {
    enum Phase: Equatable { case idle, streaming, done, failed }
    @Published var phase: Phase = .idle
    /// Cumulative rewrite text — updated on every streamed snapshot.
    @Published var rewrite: String = ""
}

/// Caret-anchored popover that lists one or more `Finding`s with optional
/// per-item fixes, plus an optional generative "Rewrite via Gemma 4" action.
///
/// Generalises SentimentGuard's original two-button popover: that popover is
/// the *single-finding* case — no findings list, a context preview of the
/// flagged text, an approve button, and a rewrite button. Clarity Checker and
/// Style Guide use the multi-finding form.
///
/// When `streaming` is provided, the primary action flips the popover into a
/// streaming-preview layout: tokens stream into a scrollable text pane and
/// the action buttons swap to Close + Copy. The caller is expected to resize
/// the host `NSPanel` separately when it starts streaming — the SwiftUI view
/// fills the available height.
@MainActor
struct FindingsPopover: View {
    let icon: String
    let headline: String
    let headlineColorName: String
    /// Flagged source text, shown as a muted preview. `nil` to omit.
    var contextPreview: String? = nil
    var findings: [Finding] = []
    /// Generative action label, e.g. "Rewrite via Gemma 4". `nil` hides it.
    var primaryActionLabel: String? = nil
    var onPrimaryAction: (() -> Void)? = nil
    /// Dismiss-and-remember label, e.g. "Looks fine". `nil` hides it.
    var approveLabel: String? = nil
    var onApprove: (() -> Void)? = nil
    /// Streaming-rewrite state. When non-nil the popover renders the streaming
    /// pane whenever `streaming.phase != .idle`.
    var streaming: StreamingRewriteState? = nil
    /// "Copy" action for the streaming pane. Required if `streaming` is set.
    var onCopy: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        if let streaming {
            FindingsPopoverStreamingBody(
                icon: icon,
                headline: headline,
                headlineColorName: headlineColorName,
                contextPreview: contextPreview,
                findings: findings,
                primaryActionLabel: primaryActionLabel,
                onPrimaryAction: onPrimaryAction,
                approveLabel: approveLabel,
                onApprove: onApprove,
                streaming: streaming,
                onCopy: onCopy,
                onDismiss: onDismiss
            )
        } else {
            idleBody
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            FindingsPopoverHeader(icon: icon, headline: headline,
                                  headlineColorName: headlineColorName,
                                  onDismiss: onDismiss)

            if let contextPreview {
                Text(contextPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if findings.isEmpty {
                Spacer(minLength: 2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(findings) { FindingRow(finding: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                if let approveLabel, let onApprove {
                    Button(approveLabel, action: onApprove)
                        .buttonStyle(.borderless)
                        .controlSize(.regular)
                }
                Spacer()
                if let primaryActionLabel, let onPrimaryAction {
                    Button(action: onPrimaryAction) {
                        Label(primaryActionLabel, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.accentColor)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(sentimentRuleColor(headlineColorName).opacity(0.25), lineWidth: 1)
        )
    }
}

/// Streaming-aware variant. Lives in its own view so it can take a non-optional
/// `@ObservedObject` — SwiftUI doesn't allow optional `@ObservedObject`s on the
/// outer `FindingsPopover` API.
@MainActor
private struct FindingsPopoverStreamingBody: View {
    let icon: String
    let headline: String
    let headlineColorName: String
    let contextPreview: String?
    let findings: [Finding]
    let primaryActionLabel: String?
    let onPrimaryAction: (() -> Void)?
    let approveLabel: String?
    let onApprove: (() -> Void)?
    @ObservedObject var streaming: StreamingRewriteState
    let onCopy: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FindingsPopoverHeader(icon: icon, headline: headline,
                                  headlineColorName: headlineColorName,
                                  onDismiss: onDismiss)

            if streaming.phase == .idle {
                idlePane
            } else {
                streamingPane
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(sentimentRuleColor(headlineColorName).opacity(0.25), lineWidth: 1)
        )
    }

    /// Default state — the findings list and the two original actions.
    @ViewBuilder private var idlePane: some View {
        if let contextPreview {
            Text(contextPreview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        if findings.isEmpty {
            Spacer(minLength: 2)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { FindingRow(finding: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }

        HStack(spacing: 8) {
            if let approveLabel, let onApprove {
                Button(approveLabel, action: onApprove)
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
            }
            Spacer()
            if let primaryActionLabel, let onPrimaryAction {
                Button(action: onPrimaryAction) {
                    Label(primaryActionLabel, systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.accentColor)
            }
        }
    }

    /// Streaming-rephrase state — tokens land here live as the model writes.
    @ViewBuilder private var streamingPane: some View {
        HStack(spacing: 6) {
            switch streaming.phase {
            case .streaming:
                ProgressView().controlSize(.small)
                Text("Rephrasing…")
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Suggested rewrite")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't rephrase")
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

        ScrollView {
            Text(displayedRewrite)
                .font(.system(size: 12))
                .foregroundStyle(streaming.phase == .failed ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity)

        HStack(spacing: 8) {
            Button("Close", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.regular)
            Spacer()
            if let onCopy {
                // Hand-styled like the IndicatorPopover's Rephrase button.
                // `.borderedProminent` over the popover's `.regularMaterial`
                // chrome renders as near-invisible white-on-frosted; explicit
                // accent fill + white text gives reliable contrast.
                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(streaming.phase == .done
                                ? Color.accentColor
                                : Color.gray.opacity(0.45))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(streaming.phase != .done)
            }
        }
    }

    /// The rewrite text, or a friendly placeholder before the first token / on
    /// failure so the pane is never just a blank box.
    private var displayedRewrite: String {
        if !streaming.rewrite.isEmpty { return streaming.rewrite }
        switch streaming.phase {
        case .failed:    return "Rewrite failed. Try again."
        case .streaming: return "…"
        default:         return ""
        }
    }
}

@MainActor
private struct FindingsPopoverHeader: View {
    let icon: String
    let headline: String
    let headlineColorName: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(sentimentRuleColor(headlineColorName))
            Text(headline)
                .font(.system(.callout, weight: .semibold))
                .foregroundColor(sentimentRuleColor(headlineColorName))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }
}

@MainActor
private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(sentimentRuleColor(finding.colorName))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.title)
                    .font(.system(size: 12, weight: .medium))
                if let detail = finding.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let fixLabel = finding.fixLabel, let onFix = finding.onFix {
                Button(fixLabel, action: onFix)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
