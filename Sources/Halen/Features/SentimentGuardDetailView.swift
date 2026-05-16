import SwiftUI

struct SentimentGuardDetailView: View {
    @Bindable var rulesStore: SentimentRulesStore
    let approvedCount: Int
    let flaggedCount: Int
    let onClearApproved: () -> Void

    @State private var showAddRule = false
    @State private var newLabel = ""
    @State private var newPrompt = ""
    @State private var newColor = "purple"
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                rulesCard
                statsCard
                modelCard
            }
            .padding(12)
        }
    }

    // MARK: - Rules card

    private var rulesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Detection rules")
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
                        RuleRow(
                            rule: rule,
                            onToggle: { rulesStore.setEnabled(rule.id, enabled: $0) },
                            onDelete: { rulesStore.remove(rule.id) }
                        )
                        if rule.id != rulesStore.sorted.last?.id {
                            Divider().padding(.leading, 30)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Label (e.g. \"Too apologetic\")", text: $newLabel)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.background.opacity(0.6))
                    )
                    .font(.system(size: 12))

                Menu {
                    ForEach(["red", "orange", "yellow", "blue", "purple", "gray"], id: \.self) { c in
                        Button(c.capitalized) { newColor = c }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(sentimentRuleColor(newColor))
                            .frame(width: 10, height: 10)
                        Text(newColor)
                            .font(.system(size: 11))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.background.opacity(0.6))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            TextField("Describe what this rule should detect (passed to Gemma)…", text: $newPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.background.opacity(0.6))
                )
                .font(.system(size: 12))
                .lineLimit(2...4)

            HStack {
                Spacer()
                Button {
                    rulesStore.addCustomRule(label: newLabel, prompt: newPrompt, colorName: newColor)
                    newLabel = ""
                    newPrompt = ""
                    newColor = "purple"
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

    // MARK: - Stats card

    private var statsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Activity")
                HStack(spacing: 0) {
                    StatPillar(
                        value: flaggedCount,
                        label: "Flagged",
                        tint: Color(red: 0.97, green: 0.58, blue: 0.20)
                    )
                    StatDivider()
                    StatPillar(
                        value: approvedCount,
                        label: "Approved",
                        tint: Color(red: 0.20, green: 0.78, blue: 0.45)
                    )
                    StatDivider()
                    StatPillar(
                        value: enabledRulesCount,
                        label: "Active rules",
                        tint: Color(red: 0.36, green: 0.50, blue: 0.95)
                    )
                }
                .padding(.vertical, 4)
                Button {
                    confirmingClear = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text("Clear approvals")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(approvedCount == 0 ? Color.secondary.opacity(0.5) : Color.red)
                .disabled(approvedCount == 0)
                .confirmationDialog("Clear \(approvedCount) approved fingerprint\(approvedCount == 1 ? "" : "s")?",
                                    isPresented: $confirmingClear,
                                    titleVisibility: .visible) {
                    Button("Clear approvals", role: .destructive) { onClearApproved() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Texts you've marked as fine will become eligible for the tone classifier again. This can't be undone.")
                }
            }
        }
    }

    private var enabledRulesCount: Int {
        rulesStore.enabledRules.count
    }

    // MARK: - Model card

    private var modelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Model")
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.tertiary)
                    Text("Routed by your inference preference")
                        .font(.system(.callout))
                    Spacer()
                    Text("See Settings")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text("Every enabled rule above goes into one classification prompt sent to whichever backend the router has available (Apple Intelligence by default, falling through to the bundled model or Ollama). The first match surfaces a popover; \"neutral\" is silent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

// MARK: - Stat pillar

private struct StatPillar: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 28)
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: SentimentRule
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sentimentRuleColor(rule.colorName))
                .frame(width: 8, height: 8)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rule.label)
                        .font(.system(.callout, weight: .medium))
                    if rule.builtin {
                        Text("BUILT-IN")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(.secondary.opacity(0.15))
                            )
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
                .opacity(hovering ? 1 : 0.7)
            }

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { onToggle($0) }
            ))
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

// `sentimentRuleColor(_:)` lives in App/Theme/HalenTheme.swift.
