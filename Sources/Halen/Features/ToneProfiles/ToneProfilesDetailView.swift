import SwiftUI

@MainActor
struct ToneProfilesDetailView: View {
    @Bindable var store: AppToneProfileStore
    @Bindable var recentApps: RecentAppsModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                assignedCard
                recentCard
                aboutCard
            }
            .padding(12)
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
                cardLabel("Recently used apps")
                let unassigned = recentApps.apps.filter { store.profiles[$0.bundleId] == nil }
                if unassigned.isEmpty {
                    Text("Apps you use will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(unassigned) { app in
                            ToneRow(
                                title: app.name,
                                subtitle: app.bundleId,
                                profile: .neutral,
                                onChange: { store.setProfile($0, for: app.bundleId) }
                            )
                        }
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
