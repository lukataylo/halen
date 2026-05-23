import SwiftUI

@MainActor
struct ClarityCheckerDetailView: View {
    @Bindable var rulesStore: ClarityRulesStore
    let flaggedCount: Int

    @State private var showAddRule = false
    @State private var newLabel = ""
    @State private var newPrompt = ""
    /// Strict / balanced / lax. See ClarityChecker.sensitivityClause for
    /// the prompt-side effect.
    @AppStorage(ClarityChecker.sensitivityKey) private var sensitivityRaw: String =
        ClarityChecker.Sensitivity.balanced.rawValue
    /// askBeforeRewrite (default) vs flagOnly (no rewrite button).
    @AppStorage(ClarityChecker.suggestionModeKey) private var suggestionModeRaw: String =
        ClarityChecker.SuggestionMode.askBeforeRewrite.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                rulesCard
                sensitivityCard
                modeCard
                aboutCard
            }
            .padding(12)
        }
    }

    // MARK: - Sensitivity / suggestion mode

    private var sensitivityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Sensitivity")
                Picker("", selection: $sensitivityRaw) {
                    Text("Strict").tag(ClarityChecker.Sensitivity.strict.rawValue)
                    Text("Balanced").tag(ClarityChecker.Sensitivity.balanced.rawValue)
                    Text("Lax").tag(ClarityChecker.Sensitivity.lax.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(sensitivityHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sensitivityHint: String {
        switch ClarityChecker.Sensitivity(rawValue: sensitivityRaw) ?? .balanced {
        case .strict:   return "Surface anything that plausibly violates a rule. Most popovers, most noise."
        case .balanced: return "Default. Flag a rule only when the text clearly violates it."
        case .lax:      return "Only flag unambiguous, material violations. Quiet by design."
        }
    }

    private var modeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("When a paragraph is flagged")
                Picker("", selection: $suggestionModeRaw) {
                    Text("Offer rewrite").tag(ClarityChecker.SuggestionMode.askBeforeRewrite.rawValue)
                    Text("Just flag").tag(ClarityChecker.SuggestionMode.flagOnly.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(modeHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeHint: String {
        switch ClarityChecker.SuggestionMode(rawValue: suggestionModeRaw) ?? .askBeforeRewrite {
        case .askBeforeRewrite: return "Popover shows the issues plus a one-tap Gemma 4 rewrite."
        case .flagOnly:         return "Popover shows the issues only. You rewrite the text yourself."
        }
    }

    private var rulesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Clarity rules")
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.2)) { showAddRule.toggle() }
                    } label: {
                        Image(systemName: showAddRule ? "minus.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                if showAddRule {
                    addRuleForm
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: 0) {
                    ForEach(rulesStore.sorted) { rule in
                        ClarityRuleRow(
                            rule: rule,
                            onToggle: { rulesStore.setEnabled(rule.id, enabled: $0) },
                            onDelete: { rulesStore.remove(rule.id) }
                        )
                        if rule.id != rulesStore.sorted.last?.id {
                            Divider().padding(.leading, 18)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (e.g. \"Nominalizations\")", text: $newLabel)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(size: 12))

            TextField("Describe the issue Gemma should look for…", text: $newPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(size: 12))
                .lineLimit(2...4)

            HStack {
                Spacer()
                Button {
                    rulesStore.addCustomRule(label: newLabel, prompt: newPrompt)
                    newLabel = ""
                    newPrompt = ""
                    withAnimation(.spring(duration: 0.2)) { showAddRule = false }
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty
                          || newPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("How it works")
                Text("Rules run when you pause typing. Matches show a popover with a rewrite option. \(flaggedCount) flagged this session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
private struct ClarityRuleRow: View {
    let rule: ClarityRule
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rule.label)
                        .font(.system(.callout, weight: .medium))
                    if rule.builtin {
                        Text("BUILT-IN")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                    }
                }
                Text(rule.prompt)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !rule.builtin {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
