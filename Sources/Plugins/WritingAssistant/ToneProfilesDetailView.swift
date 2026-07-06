import SwiftUI

/// Per-app target-tone editor, surfaced inside the Writing Assistant's Tone
/// tab. Renders as a plain `VStack` (no ScrollView of its own) so it can sit
/// among the other cards in `SentimentGuardDetailView`'s scroll view. The user
/// assigns an expected register (Formal / Business casual / Casual) to the apps
/// they care about; Sentiment Guard flags messages that read less formal than
/// that target. Apps left Neutral impose no target.
@MainActor
struct ToneProfilesEditor: View {
    @Bindable var store: AppToneProfileStore
    @Bindable var recentApps: RecentAppsModel
    /// Set of bundle ids the user has multi-selected in the unassigned list.
    /// Used by the bulk-assign affordance — apply one tone to N apps at once.
    @State private var multiSelection: Set<String> = []

    var body: some View {
        VStack(spacing: 10) {
            assignedCard
            recentCard
        }
    }

    // MARK: - Assigned profiles

    private var assignedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Expected tone per app")
                if store.sortedEntries.isEmpty {
                    Text("No apps set yet. Pick an app below and choose the tone you write in there — e.g. Outlook → Formal, Teams → Business casual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.sortedEntries, id: \.bundleId) { entry in
                            ToneRow(
                                title: displayName(for: entry.bundleId),
                                subtitle: entry.bundleId,
                                profile: entry.profile,
                                onChange: { store.setProfile($0, for: entry.bundleId) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recently used apps

    private var recentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    cardLabel("Add an app")
                    Spacer()
                    if !multiSelection.isEmpty {
                        Text("\(multiSelection.count) selected")
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
                let unassigned = recentApps.apps.filter { store.profiles[$0.bundleId] == nil }
                if unassigned.isEmpty {
                    Text("Apps you use will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(unassigned) { app in
                            SelectableToneRow(
                                title: app.name,
                                subtitle: app.bundleId,
                                isSelected: multiSelection.contains(app.bundleId),
                                onToggleSelection: {
                                    if multiSelection.contains(app.bundleId) {
                                        multiSelection.remove(app.bundleId)
                                    } else {
                                        multiSelection.insert(app.bundleId)
                                    }
                                },
                                onAssign: {
                                    store.setProfile($0, for: app.bundleId)
                                    // The row leaves the unassigned list now —
                                    // drop it from any pending bulk selection so
                                    // a later bulk tap can't overwrite this pick.
                                    multiSelection.remove(app.bundleId)
                                }
                            )
                        }
                    }

                    // Bulk-assign bar appears once at least one row is
                    // selected — applies the chosen tone to every checked
                    // app and clears the selection.
                    if !multiSelection.isEmpty {
                        HStack(spacing: 6) {
                            Text("Apply to selected:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Neutral is "no target" — assigning it here would
                            // just clear the row, so only offer real registers.
                            ForEach(ToneProfile.allCases.filter { $0 != .neutral }) { tone in
                                Button(tone.label) {
                                    for bundleId in multiSelection {
                                        store.setProfile(tone, for: bundleId)
                                    }
                                    multiSelection.removeAll()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityHint("Applies the \(tone.label) tone to the selected apps.")
                            }
                            Spacer()
                            Button("Clear") {
                                multiSelection.removeAll()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityHint("Deselects every app in the selection.")
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func displayName(for bundleId: String) -> String {
        recentApps.apps.first(where: { $0.bundleId == bundleId })?.name ?? bundleId
    }
}

@MainActor
private struct ToneRow: View {
    let title: String
    let subtitle: String
    let profile: ToneProfile
    let onChange: (ToneProfile) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { profile }, set: { onChange($0) })) {
                ForEach(ToneProfile.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Expected tone for \(title)")
            .accessibilityHint("Choose the register Sentiment Guard holds your writing to in this app.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}

/// Same shape as `ToneRow` but with a leading checkbox for multi-select.
/// The picker still lets the user assign one app at a time without
/// touching the checkbox — selecting is for the bulk-assign workflow only.
@MainActor
private struct SelectableToneRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onAssign: (ToneProfile) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleSelection) {
                // .body keeps the 14pt visual weight while scaling with Dynamic Type.
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Remove from selection" : "Add to selection")
            .accessibilityLabel(isSelected ? "Deselect \(title)" : "Select \(title)")
            .accessibilityHint("Toggles \(title) in the bulk-assign selection.")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { ToneProfile.neutral }, set: { onAssign($0) })) {
                Text("Set tone…").tag(ToneProfile.neutral)
                ForEach(ToneProfile.allCases.filter { $0 != .neutral }) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Assign tone to \(title)")
            .accessibilityHint("Picks the expected register for this app.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
