import SwiftUI

@MainActor
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

    /// Conciseness check — surfaces wordy filler phrases alongside the tone
    /// classifier. On by default; the scan is rule-based and free.
    @AppStorage(SentimentGuard.concisenessDefaultsKey) private var concisenessEnabled = true
    /// Strict / balanced / lax — see SentimentGuard.sensitivityClause.
    @AppStorage(SentimentGuard.sensitivityKey) private var sensitivityRaw: String =
        SentimentGuard.Sensitivity.balanced.rawValue
    /// Comma-separated bundle ids. Bound directly to defaults via @AppStorage
    /// so changes are picked up by the running plugin's eligibility check
    /// on the next typed paragraph.
    @AppStorage(SentimentGuard.ignoredAppsKey) private var ignoredAppsCSV: String = ""
    /// Local-only field for adding a new bundle id to the silence list.
    @State private var newIgnoredApp: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                rulesCard
                sensitivityCard
                ignoredAppsCard
                concisenessCard
                statsCard
                modelCard
            }
            .padding(12)
        }
    }

    // MARK: - Sensitivity

    private var sensitivityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Sensitivity")
                Picker("", selection: $sensitivityRaw) {
                    Text("Strict").tag(SentimentGuard.Sensitivity.strict.rawValue)
                    Text("Balanced").tag(SentimentGuard.Sensitivity.balanced.rawValue)
                    Text("Lax").tag(SentimentGuard.Sensitivity.lax.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Sentiment sensitivity")
                .accessibilityHint("Strict catches more, lax stays quieter.")
                // Semantic .caption — Larger Accessibility Sizes scales this hint.
                Text(sensitivityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sensitivityHint: String {
        switch SentimentGuard.Sensitivity(rawValue: sensitivityRaw) ?? .balanced {
        case .strict:   return "Flag the slightest hint of the labelled tones. More popovers, more false positives."
        case .balanced: return "Default. Flag only when the text clearly matches an enabled rule."
        case .lax:      return "Only flag strong, unambiguous matches. Fewer popovers, less likely to misjudge."
        }
    }

    // MARK: - Per-app ignore list

    /// Persisted CSV split into a usable list. Kept as a computed accessor
    /// so the view always reflects the latest defaults value.
    private var ignoredApps: [String] {
        ignoredAppsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var ignoredAppsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Ignored apps")
                Text("Sentiment Guard stays silent in these apps. Type a bundle id (e.g. com.apple.iChat).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    TextField("com.apple.iChat", text: $newIgnoredApp)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                        .accessibilityLabel("New ignored bundle id")
                        .accessibilityHint("Type a bundle id like com.apple.iChat to silence Sentiment Guard there.")
                    Button {
                        addIgnoredApp()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(newIgnoredApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(newIgnoredApp.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.secondary.opacity(0.4) : Color.accentColor)
                    .accessibilityLabel("Add bundle id to ignore list")
                    .accessibilityHint("Adds the bundle id you just typed so Sentiment Guard stops firing there.")
                }

                if ignoredApps.isEmpty {
                    // size: 10.5 ignored Dynamic Type; .caption2 is the smallest
                    // semantic step and still keeps the row visually quiet.
                    Text("No apps ignored.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ignoredApps, id: \.self) { bundleId in
                            HStack {
                                Text(bundleId)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button {
                                    removeIgnoredApp(bundleId)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from ignore list")
                                .accessibilityLabel("Remove \(bundleId) from ignore list")
                                .accessibilityHint("Sentiment Guard will fire in this app again.")
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func addIgnoredApp() {
        let trimmed = newIgnoredApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Defensive: dedup against the existing list.
        var current = ignoredApps
        guard !current.contains(trimmed) else {
            newIgnoredApp = ""
            return
        }
        current.append(trimmed)
        ignoredAppsCSV = current.joined(separator: ",")
        newIgnoredApp = ""
    }

    private func removeIgnoredApp(_ bundleId: String) {
        var current = ignoredApps
        current.removeAll { $0 == bundleId }
        ignoredAppsCSV = current.joined(separator: ",")
    }

    // MARK: - Conciseness card

    private var concisenessCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    cardLabel("Conciseness check")
                    Spacer()
                    Toggle("", isOn: $concisenessEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityLabel("Conciseness check")
                        .accessibilityHint("Turns the wordy-phrase scan on or off.")
                }
                Text("Flags wordy phrases like \"in order to\" and \"the fact that\". Instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(showAddRule ? "Cancel new detection rule" : "Add detection rule")
                    .accessibilityHint(showAddRule
                                       ? "Closes the add-rule form."
                                       : "Opens a form to add a new sentiment detection rule.")
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
                    .font(.callout)
                    .accessibilityLabel("Rule label")
                    .accessibilityHint("Short name shown in the rules list.")

                Menu {
                    ForEach(["red", "orange", "yellow", "blue", "purple", "gray"], id: \.self) { c in
                        Button(c.capitalized) { newColor = c }
                    }
                } label: {
                    HStack(spacing: 4) {
                        // Decorative swatch — the colour name to its right is
                        // the canonical label VoiceOver reads.
                        Circle()
                            .fill(sentimentRuleColor(newColor))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(newColor)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .accessibilityHidden(true)
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
                .accessibilityLabel("Rule color")
                .accessibilityValue(newColor)
                .accessibilityHint("Pick the badge colour for this rule.")
            }

            TextField("Describe what this rule should detect (passed to Gemma)…", text: $newPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.background.opacity(0.6))
                )
                .font(.callout)
                .lineLimit(2...4)
                .accessibilityLabel("Rule prompt")
                .accessibilityHint("Describe what Gemma should detect to trigger this rule.")

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
                .accessibilityHint("Saves the new detection rule and closes the form.")
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
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text("Clear approvals")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(approvedCount == 0 ? Color.secondary.opacity(0.5) : Color.red)
                .disabled(approvedCount == 0)
                .accessibilityHint("Clears the list of paragraphs you've previously marked as fine.")
                .confirmationDialog("Clear approved texts?",
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
                        .accessibilityHidden(true)
                    Text("Routed by your inference preference")
                        .font(.system(.callout))
                    Spacer()
                    Text("See Settings")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("Rules run when you pause typing. First match shows a popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

// MARK: - Stat pillar

@MainActor
private struct StatPillar: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            // .title2 keeps the prominent display look while scaling with Dynamic Type.
            Text("\(value)")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

@MainActor
private struct StatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 28)
    }
}

// MARK: - Row

@MainActor
private struct RuleRow: View {
    let rule: SentimentRule
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // The colour swatch is decorative — the rule's label right after
            // it carries the meaning. VoiceOver picks up the colour through
            // the toggle's accessibility label below.
            Circle()
                .fill(sentimentRuleColor(rule.colorName))
                .frame(width: 8, height: 8)
                .padding(.leading, 2)
                .accessibilityLabel("\(rule.colorName.capitalized) severity")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rule.label)
                        .font(.system(.callout, weight: .medium))
                    if rule.builtin {
                        Text("BUILT-IN")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(.secondary.opacity(0.15))
                            )
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
                .opacity(hovering ? 1 : 0.7)
                .accessibilityLabel("Delete rule \(rule.label)")
                .accessibilityHint("Removes this custom detection rule.")
            }

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Enable rule \(rule.label)")
            .accessibilityHint("Turns this sentiment detection rule on or off.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// `sentimentRuleColor(_:)` lives in App/Theme/HalenTheme.swift.
