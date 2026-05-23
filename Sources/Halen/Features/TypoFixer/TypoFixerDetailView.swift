import SwiftUI

@MainActor
struct TypoFixerDetailView: View {
    @Bindable var store: TypoStore
    @State private var newTypo: String = ""
    @State private var newCorrection: String = ""
    @State private var search: String = ""
    @State private var confirmingReset = false
    @FocusState private var typoFieldFocused: Bool
    /// User-tunable "how many times must I see a typo before auto-fixing?"
    /// Stored at the global defaults key so the running TypoStore reads
    /// the latest value live (it's a `var` not a `let` on the store).
    @AppStorage(TypoStore.activeThresholdKey) private var activeThreshold: Int = TypoStore.activeThresholdDefault

    var body: some View {
        VStack(spacing: 10) {
            thresholdCard
            addCard
            searchField
            entriesList
            footer
        }
        .padding(12)
    }

    // MARK: - Threshold

    /// "How aggressive should auto-correct be?" — the only real per-user
    /// tuning knob for Typo Fixer. Three labelled positions on the slider
    /// (aggressive / balanced / conservative) cover most of what the user
    /// would actually want; finer than that is just noise.
    private var thresholdCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Auto-fix sensitivity")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                    Spacer()
                    Text(thresholdLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                let lo = Double(TypoStore.activeThresholdRange.lowerBound)
                let hi = Double(TypoStore.activeThresholdRange.upperBound)
                Slider(
                    value: Binding(
                        get: { Double(activeThreshold) },
                        set: { activeThreshold = Int($0.rounded()) }
                    ),
                    in: lo...hi,
                    step: 1
                )
                Text(thresholdHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var thresholdLabel: String {
        switch activeThreshold {
        case 1: return "1 — aggressive"
        case 2: return "2 — balanced"
        case 3: return "3 — careful"
        case 4: return "4 — conservative"
        default: return "\(activeThreshold) — very conservative"
        }
    }

    private var thresholdHint: String {
        switch activeThreshold {
        case 1: return "Halen auto-fixes after seeing a typo once. Catches more, false-positives more."
        case 2: return "Default. Auto-fixes after two confirmations from your edits."
        case 3: return "Waits for three confirmations before activating an entry. Quieter."
        default: return "Auto-fixes only after \(activeThreshold) observations. Personal seeds and user-added entries skip the warm-up."
        }
    }

    // MARK: - Add new

    private var addCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add a correction")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                HStack(spacing: 8) {
                    TextField("typo", text: $newTypo)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.background.opacity(0.6))
                        )
                        .focused($typoFieldFocused)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    TextField("correction", text: $newCorrection)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.background.opacity(0.6))
                        )

                    Button {
                        addEntry()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(newTypo.isEmpty || newCorrection.isEmpty)
                    .foregroundStyle(newTypo.isEmpty || newCorrection.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .font(.system(size: 12))
            }
        }
    }

    private func addEntry() {
        store.addUserEntry(typo: newTypo, correction: newCorrection)
        newTypo = ""
        newCorrection = ""
        typoFieldFocused = true
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter \(store.entries.count) entries", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Entries list

    private var filteredEntries: [(key: String, entry: TypoStore.Entry)] {
        let all = store.sortedEntries
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter { $0.key.contains(q) || $0.entry.correction.lowercased().contains(q) }
    }

    private var entriesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredEntries, id: \.key) { item in
                    EntryRow(
                        key: item.key,
                        entry: item.entry,
                        onDelete: { store.remove(typo: item.key) },
                        onSave:   { newCorrection in
                            // `addUserEntry` upserts and re-arms to active —
                            // exactly the semantics the user expects from
                            // an inline edit.
                            store.addUserEntry(typo: item.key, correction: newCorrection)
                        }
                    )
                    if item.key != filteredEntries.last?.key {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
        .frame(maxHeight: 240)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) of \(store.entries.count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Open JSON") {
                NSWorkspace.shared.open(TypoStore.fileURL)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Button("Reset all") {
                confirmingReset = true
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.red)
            .confirmationDialog("Reset the typo dictionary?",
                                isPresented: $confirmingReset,
                                titleVisibility: .visible) {
                Button("Reset all (\(store.entries.count) entries)",
                       role: .destructive) {
                    store.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Custom corrections you've added will be deleted. Built-in seeds will be restored on next launch.")
            }
        }
    }
}

@MainActor
private struct EntryRow: View {
    let key: String
    let entry: TypoStore.Entry
    let onDelete: () -> Void
    /// Called with a new correction string when the user submits an inline
    /// edit. The parent passes a closure that upserts via `TypoStore`.
    let onSave: (String) -> Void

    @State private var hovering = false
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if isEditing {
                        TextField("", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(.callout, design: .monospaced))
                            .focused($editorFocused)
                            .onSubmit(commit)
                            .frame(minWidth: 120)
                            .onExitCommand { cancelEdit() }
                    } else {
                        Text(entry.correction)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
                Text(isEditing
                     ? "⏎ save · ⎋ cancel"
                     : "\(entry.observations) observation\(entry.observations == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isEditing {
                Button("Save", action: commit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Cancel", action: cancelEdit)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering || isEditing ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { beginEdit() }
        .help(isEditing ? "" : "Double-click to edit the correction.")
    }

    private func beginEdit() {
        guard !isEditing else { return }
        draft = entry.correction
        isEditing = true
        editorFocused = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != entry.correction {
            onSave(trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
        draft = ""
    }
}
