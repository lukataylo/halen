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
                .accessibilityLabel("Clarity sensitivity")
                .accessibilityHint("Strict catches more, lax stays quieter.")
                // Semantic .caption — Larger Accessibility Sizes scales hint rows.
                Text(sensitivityHint)
                    .font(.caption)
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
                .accessibilityLabel("Flag behaviour")
                .accessibilityHint("Choose whether Halen offers a rewrite or just flags the paragraph.")
                Text(modeHint)
                    .font(.caption)
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
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(showAddRule ? "Cancel new rule" : "Add a new clarity rule")
                    .accessibilityHint(showAddRule
                                       ? "Closes the add-rule form."
                                       : "Opens a form to add a new clarity rule.")
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
            // Semantic .callout for both fields — Dynamic Type respects this.
            TextField("Label (e.g. \"Nominalizations\")", text: $newLabel)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.callout)
                .accessibilityLabel("Rule label")
                .accessibilityHint("Short name shown in the rules list.")

            TextField("Describe the issue Gemma should look for…", text: $newPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.callout)
                .lineLimit(2...4)
                .accessibilityLabel("Rule prompt")
                .accessibilityHint("Tell Gemma what kind of writing issue this rule should catch.")

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
                .accessibilityHint("Saves the new clarity rule and closes the form.")
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
                    .font(.caption)
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
                        // size: 9 was below the smallest semantic step; .caption2
                        // scales with Dynamic Type and keeps the badge legible.
                        Text("BUILT-IN")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                    }
                }
                Text(rule.prompt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !rule.builtin {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete rule \(rule.label)")
                .accessibilityHint("Removes this custom clarity rule.")
            }
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Enable rule \(rule.label)")
                .accessibilityHint("Turns this clarity rule on or off.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
