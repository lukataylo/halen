import SwiftUI

@MainActor
struct ToneProfilesDetailView: View {
    @Bindable var store: AppToneProfileStore
    @Bindable var recentApps: RecentAppsModel
    /// Set of bundle ids the user has multi-selected in the unassigned list.
    /// Used by the bulk-assign affordance — apply one tone to N apps at once.
    @State private var multiSelection: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                assignedCard
                recentCard
                tonesCard
                aboutCard
            }
            .padding(12)
        }
    }

    // MARK: - Tone descriptions

    /// Surface the prompt clauses Halen actually feeds the model so the
    /// user can see what each tone profile *does*. The strings live on
    /// `ToneProfile.promptClause`; rendered here as a small reference card
    /// rather than hidden inside the picker.
    private var tonesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("What each tone means")
                ForEach(ToneProfile.allCases) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.label)
                            .font(.system(size: 12, weight: .semibold))
                        Text(profile.promptClause)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                    if profile != ToneProfile.allCases.last {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    // MARK: - Assigned profiles

    private var assignedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("App tone profiles")
                if store.sortedEntries.isEmpty {
                    Text("Choose a tone for each app below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                    cardLabel("Recently used apps")
                    Spacer()
                    if !multiSelection.isEmpty {
                        Text("\(multiSelection.count) selected")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                let unassigned = recentApps.apps.filter { store.profiles[$0.bundleId] == nil }
                if unassigned.isEmpty {
                    Text("Apps you use will appear here.")
                        .font(.system(size: 11))
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
                                onAssign: { store.setProfile($0, for: app.bundleId) }
                            )
                        }
                    }

                    // Bulk-assign bar appears once at least one row is
                    // selected — applies the chosen tone to every checked
                    // app and clears the selection.
                    if !multiSelection.isEmpty {
                        HStack(spacing: 6) {
                            Text("Apply to selected:")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            ForEach(ToneProfile.allCases) { tone in
                                Button(tone.label) {
                                    for bundleId in multiSelection {
                                        store.setProfile(tone, for: bundleId)
                                    }
                                    multiSelection.removeAll()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Spacer()
                            Button("Clear") {
                                multiSelection.removeAll()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("How it's used")
                Text("Rules adjust to the app you're in. Slack gets different rules than Mail.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 10))
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
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Remove from selection" : "Add to selection")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { ToneProfile.neutral }, set: { onAssign($0) })) {
                ForEach(ToneProfile.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}
