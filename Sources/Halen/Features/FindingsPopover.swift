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

/// Caret-anchored popover that lists one or more `Finding`s with optional
/// per-item fixes, plus an optional generative "Rewrite via Gemma 4" action.
///
/// Generalises SentimentGuard's original two-button popover: that popover is
/// the *single-finding* case — no findings list, a context preview of the
/// flagged text, an approve button, and a rewrite button. Clarity Checker and
/// Style Guide use the multi-finding form.
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
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(headlineColor)
                Text(headline)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(headlineColor)
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

            if let contextPreview {
                Text(contextPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if findings.isEmpty {
                Spacer(minLength: 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(findings) { FindingRow(finding: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                if let approveLabel, let onApprove {
                    Button(approveLabel, action: onApprove)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Spacer()
                if let primaryActionLabel, let onPrimaryAction {
                    Button(action: onPrimaryAction) {
                        Label(primaryActionLabel, systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(headlineColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var headlineColor: Color { sentimentRuleColor(headlineColorName) }
}

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
