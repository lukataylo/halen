import SwiftUI

@MainActor
struct StyleGuideDetailView: View {
    @Bindable var store: StyleRulesStore

    @State private var showAddRule = false
    @State private var newBanned = ""
    @State private var newPreferred = ""
    @State private var newKind: StyleRuleKind = .literal
    /// Transient toast after a CSV import — `(imported, skipped)`.
    @State private var lastImport: (imported: Int, skipped: Int)?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                rulesCard
                importCard
                aboutCard
            }
            .padding(12)
        }
    }

    // MARK: - CSV import

    private var importCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Import / export")
                Text("Bulk-load rules from a CSV file. Format: banned,preferred,kind. The header row is optional; kind defaults to literal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        importCSVFile()
                    } label: {
                        Label("Import CSV…", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .accessibilityHint("Opens a file picker to import style rules from CSV.")
                    Button {
                        exportCSVFile()
                    } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                    .accessibilityHint("Saves your custom style rules to a CSV file.")
                    Spacer()
                }
                if let li = lastImport {
                    Text(li.skipped == 0
                         ? "Imported \(li.imported) rule\(li.imported == 1 ? "" : "s")."
                         : "Imported \(li.imported), skipped \(li.skipped).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func importCSVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8)
        else { return }
        lastImport = store.importCSV(csv)
    }

    private func exportCSVFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "halen-style-rules.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var out = "banned,preferred,kind\n"
        // Export only user rules — exporting the three built-ins back into
        // the user's own CSV would round-trip noise.
        for rule in store.sorted where !rule.builtin {
            // Crude CSV escaping: quote any field containing comma or quote.
            func esc(_ s: String) -> String {
                if s.contains(",") || s.contains("\"") {
                    return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return s
            }
            out += "\(esc(rule.banned)),\(esc(rule.preferred)),\(rule.kind.rawValue)\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
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
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(showAddRule ? "Cancel new rule" : "Add a new style rule")
                    .accessibilityHint(showAddRule
                                       ? "Closes the add-rule form."
                                       : "Opens a form to add a new style rule.")
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
            Picker("", selection: $newKind) {
                Text("Literal").tag(StyleRuleKind.literal)
                Text("Regex").tag(StyleRuleKind.regex)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Rule kind")
            .accessibilityHint("Literal matches a fixed phrase; regex matches a pattern.")

            // size: 12 was a half-step under .body and ignored Dynamic Type.
            // .callout scales properly while keeping the visual hierarchy.
            TextField(
                newKind == .literal
                    ? "Banned term (e.g. \"synergy\")"
                    : "Regex pattern (e.g. \\bcolou?r\\b)",
                text: $newBanned)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.system(.callout, design: newKind == .regex ? .monospaced : .default))
                .accessibilityLabel(newKind == .literal ? "Banned term" : "Regex pattern")
                .accessibilityHint("The text or pattern Halen should flag.")

            TextField("Preferred term (leave blank to just ban it)", text: $newPreferred)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
                .font(.callout)
                .accessibilityLabel("Preferred term")
                .accessibilityHint("Optional replacement Halen suggests for the banned term.")

            // Inline validation: a regex with a syntax error would fail
            // silently at scan time, looking like a Halen bug. Surface it
            // up-front so the user fixes the pattern before saving.
            if newKind == .regex, !newBanned.isEmpty, !regexIsValid {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Invalid regex syntax")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button {
                    store.addCustomRule(banned: newBanned, preferred: newPreferred, kind: newKind)
                    newBanned = ""
                    newPreferred = ""
                    newKind = .literal
                    withAnimation(.spring(duration: 0.2)) { showAddRule = false }
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAddRule)
                .accessibilityHint("Saves the new style rule and closes the form.")
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

    /// Form validation: requires a non-empty banned field plus (for regex
    /// rules) a syntactically valid pattern.
    private var canAddRule: Bool {
        let trimmed = newBanned.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if newKind == .regex { return regexIsValid }
        return true
    }

    private var regexIsValid: Bool {
        (try? NSRegularExpression(
            pattern: newBanned.trimmingCharacters(in: .whitespaces),
            options: [.caseInsensitive])) != nil
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("How it works")
                Text("Highlights banned words as you type. Tap Replace to use the preferred wording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
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
                            .font(.caption2)
                            .fontWeight(.semibold)
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
                        .font(.caption2)
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete rule")
                .accessibilityHint("Removes this custom style rule.")
            }
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(rule.isProhibition
                                    ? "Avoid \(rule.banned)"
                                    : "Replace \(rule.banned) with \(rule.preferred)")
                .accessibilityHint("Turns this style rule on or off.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
