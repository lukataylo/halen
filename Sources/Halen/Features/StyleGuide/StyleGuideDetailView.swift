import SwiftUI

struct StyleGuideDetailView: View {
    @Bindable var store: StyleRulesStore

    @State private var showAddRule = false
    @State private var newBanned = ""
    @State private var newPreferred = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                rulesCard
                aboutCard
            }
            .padding(12)
        }
    }

    private var rulesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Style rules")
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
                    ForEach(store.sorted) { rule in
                        StyleRuleRow(
                            rule: rule,
                            onToggle: { store.setEnabled(rule.id, enabled: $0) },
                            onDelete: { store.remove(rule.id) }
                        )
                        if rule.id != store.sorted.last?.id {
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
            TextField("Banned term (e.g. \"synergy\")", text: $newBanned)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(size: 12))

            TextField("Preferred term (leave blank to just ban it)", text: $newPreferred)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(size: 12))

            HStack {
                Spacer()
                Button {
                    store.addCustomRule(banned: newBanned, preferred: newPreferred)
                    newBanned = ""
                    newPreferred = ""
                    withAnimation(.spring(duration: 0.2)) { showAddRule = false }
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newBanned.trimmingCharacters(in: .whitespaces).isEmpty)
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
                Text("As you type, Halen scans each paragraph for your banned terms — no AI, instant, fully deterministic. Matches appear in a popover; rules with a preferred term get a one-tap Replace.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StyleRuleRow: View {
    let rule: StyleRule
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if rule.isProhibition {
                        Text("Avoid “\(rule.banned)”")
                            .font(.system(.callout, weight: .medium))
                    } else {
                        Text("“\(rule.banned)” → “\(rule.preferred)”")
                            .font(.system(.callout, weight: .medium))
                    }
                    if rule.builtin {
                        Text("BUILT-IN")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                    }
                }
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
