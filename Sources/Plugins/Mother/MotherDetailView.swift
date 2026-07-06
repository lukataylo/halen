import HalenPluginAPI
import SwiftUI

/// Settings for Mother: enforcement level, focus hours, and the two
/// blocklists. Edits write straight through the store to `config.json` —
/// the same file the out-of-process Python plugin used, so hand edits and
/// UI edits coexist (the file is hot-reloaded either way).
@MainActor
struct MotherDetailView: View {
    let store: MotherConfigStore

    @State private var newBundleId = ""
    @State private var newAppName = ""
    @State private var newSite = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                statusCard
                enforcementCard
                focusHoursCard
                blockedAppsCard
                blockedSitesCard
                aboutCard
            }
            .padding(12)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Status")
                // Periodic so the line flips by itself when focus hours
                // start or end while the popover is open.
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    let mode = store.config.effectiveMode(at: timeline.date)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(for: mode))
                            .frame(width: 8, height: 8)
                        Text(statusText(for: mode, at: timeline.date))
                            .font(.system(.callout, weight: .medium))
                    }
                }
                Text("\(store.state.totalQuits) app\(store.state.totalQuits == 1 ? "" : "s") quit · "
                    + "\(store.state.totalTabsClosed) tab\(store.state.totalTabsClosed == 1 ? "" : "s") closed · "
                    + "\(store.state.overrides) override\(store.state.overrides == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(for mode: MotherMode, at date: Date) -> String {
        switch mode {
        case .off:
            return "Idle — enforcement is off."
        case .warn:
            return "Watching — warnings only, nothing gets closed."
        case .enforceNoOverride:
            return store.config.inFocusHours(at: date)
                ? "Enforcing — focus hours are in session."
                : "Enforcing — lockdown, no overrides, ever."
        case .enforceOverride:
            return "Watching — outside focus hours. Mother confronts before she closes."
        }
    }

    private func statusColor(for mode: MotherMode) -> Color {
        switch mode {
        case .off: return Color(white: 0.55)
        case .warn: return Color(red: 0.93, green: 0.80, blue: 0.20)
        case .enforceNoOverride: return Color(red: 0.92, green: 0.27, blue: 0.27)
        case .enforceOverride: return Color(red: 0.97, green: 0.58, blue: 0.20)
        }
    }

    // MARK: - Enforcement

    private enum EnforcementChoice: String, CaseIterable {
        case off, soft, hardcore, lockdown

        var label: String {
            switch self {
            case .off: return "Off"
            case .soft: return "Soft"
            case .hardcore: return "Hardcore"
            case .lockdown: return "Lockdown"
            }
        }

        var blurb: String {
            switch self {
            case .off:
                return "Mother stands down. Nothing is watched, nothing is logged."
            case .soft:
                return "A stern notification, logged. Nothing is closed."
            case .hardcore:
                return "Inside focus hours she quits the app / closes the tab, no override. Outside focus hours she confronts first."
            case .lockdown:
                return "Always immediate. No prompt, no override, ever."
            }
        }
    }

    private var enforcementBinding: Binding<EnforcementChoice> {
        Binding(
            get: {
                switch store.config.enforcement
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "off", "disabled", "none": return .off
                case "hardcore": return .hardcore
                case "lockdown": return .lockdown
                // "soft" and anything unrecognized — the runtime treats an
                // unknown value as soft too (fail safe, never escalate).
                default: return .soft
                }
            },
            set: { choice in
                store.update { $0.enforcement = choice.rawValue }
            }
        )
    }

    private var enforcementCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Enforcement")
                Picker("", selection: enforcementBinding) {
                    ForEach(EnforcementChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Enforcement level")
                Text(enforcementBinding.wrappedValue.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Focus hours

    private var focusHoursCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardLabel("Focus hours")
                    Spacer()
                    Button {
                        store.update {
                            $0.focusHours.append(MotherFocusWindow(
                                days: [0, 1, 2, 3, 4], start: "09:00", end: "18:00"))
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Add a focus window")
                }

                if store.config.focusHours.isEmpty {
                    Text("No focus windows. In hardcore mode Mother will always confront before closing; add a window to make her relentless during it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.config.focusHours.enumerated()), id: \.offset) { index, window in
                            FocusWindowRow(
                                window: window,
                                onChange: { updated in
                                    store.update { cfg in
                                        guard cfg.focusHours.indices.contains(index) else { return }
                                        cfg.focusHours[index] = updated
                                    }
                                },
                                onDelete: {
                                    store.update { cfg in
                                        guard cfg.focusHours.indices.contains(index) else { return }
                                        cfg.focusHours.remove(at: index)
                                    }
                                })
                            if index < store.config.focusHours.count - 1 {
                                Divider()
                            }
                        }
                    }
                }

                Text("A window whose end is at or before its start spans midnight (e.g. 22:00–06:00).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Blocked apps

    private var blockedAppsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Blocked apps")

                if store.config.blockedApps.isEmpty {
                    Text("No apps blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.config.blockedApps) { app in
                            BlocklistRow(
                                title: app.name,
                                subtitle: app.bundleId,
                                onDelete: {
                                    store.update { cfg in
                                        cfg.blockedApps.removeAll { $0.bundleId == app.bundleId }
                                    }
                                })
                            if app.bundleId != store.config.blockedApps.last?.bundleId {
                                Divider().padding(.leading, 2)
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    smallField("Bundle id (e.g. com.hnc.Discord)", text: $newBundleId, monospaced: true)
                    smallField("Name (optional)", text: $newAppName, monospaced: false)
                    Button {
                        addBlockedApp()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .disabled(newBundleId.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add blocked app")
                }
            }
        }
    }

    private func addBlockedApp() {
        let bundleId = newBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else { return }
        let name = newAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update { cfg in
            guard !cfg.blockedApps.contains(where: { $0.bundleId == bundleId }) else { return }
            cfg.blockedApps.append(MotherBlockedApp(
                bundleId: bundleId,
                name: name.isEmpty ? bundleId : name))
        }
        newBundleId = ""
        newAppName = ""
    }

    // MARK: - Blocked sites

    private var blockedSitesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Blocked sites")

                if store.config.blockedSites.isEmpty {
                    Text("No sites blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.config.blockedSites, id: \.self) { site in
                            BlocklistRow(
                                title: site,
                                subtitle: nil,
                                onDelete: {
                                    store.update { cfg in
                                        cfg.blockedSites.removeAll { $0 == site }
                                    }
                                })
                            if site != store.config.blockedSites.last {
                                Divider().padding(.leading, 2)
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    smallField("Host (e.g. reddit.com — subdomains included)", text: $newSite, monospaced: true)
                    Button {
                        addBlockedSite()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add blocked site")
                }
            }
        }
    }

    private func addBlockedSite() {
        var site = newSite.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept a pasted URL and store just the host, the shape rules use.
        if site.contains("://") || site.contains("/") {
            site = Mother.hostOf(site)
        }
        while site.hasPrefix(".") { site.removeFirst() }
        guard !site.isEmpty else { return }
        store.update { cfg in
            guard !cfg.blockedSites.contains(site) else { return }
            cfg.blockedSites.append(site)
        }
        newSite = ""
    }

    // MARK: - About

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("How it works")
                Text("When a blocked app takes focus, a short grace timer starts; if it's still frontmost when the timer elapses, Mother acts. While a supported browser is frontmost she reads the front tab every few seconds and matches it against the site list (a rule blocks the host and its subdomains). Everything is local and logged to her ledger; overrides are always recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Small shared bits

    private func smallField(_ placeholder: String, text: Binding<String>, monospaced: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
    }
}

// MARK: - Rows

@MainActor
private struct BlocklistRow: View {
    let title: String
    let subtitle: String?
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, weight: .medium))
                if let subtitle, subtitle != title {
                    Text(subtitle)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title) from the blocklist")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One focus window: day chips (Mon-first, matching the config's 0=Mon
/// convention) plus start/end "HH:MM" fields that commit on submit.
@MainActor
private struct FocusWindowRow: View {
    let window: MotherFocusWindow
    let onChange: (MotherFocusWindow) -> Void
    let onDelete: () -> Void

    @State private var start = ""
    @State private var end = ""
    @State private var hovering = false

    private static let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday",
                                   "Friday", "Saturday", "Sunday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { day in
                    dayChip(day)
                }
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this focus window")
            }
            HStack(spacing: 6) {
                timeField("09:00", text: $start, label: "Start time")
                Text("–").foregroundStyle(.secondary)
                timeField("18:00", text: $end, label: "End time")
                if !timesValid {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("Use 24h HH:MM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear {
            start = window.start
            end = window.end
        }
        .onChange(of: window) { _, updated in
            start = updated.start
            end = updated.end
        }
    }

    private func dayChip(_ day: Int) -> some View {
        let active = window.days.contains(day)
        return Button {
            var updated = window
            if active {
                updated.days.removeAll { $0 == day }
            } else {
                updated.days.append(day)
                updated.days.sort()
            }
            onChange(updated)
        } label: {
            Text(Self.dayLabels[day])
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(active ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.dayNames[day])
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func timeField(_ placeholder: String, text: Binding<String>, label: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .frame(width: 52)
            .multilineTextAlignment(.center)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
            .onSubmit(commitTimes)
            .accessibilityLabel(label)
            .accessibilityHint("24-hour time, like 09:00.")
    }

    private var timesValid: Bool {
        MotherConfig.parseHM(start) != nil && MotherConfig.parseHM(end) != nil
    }

    private func commitTimes() {
        guard timesValid else { return }
        var updated = window
        updated.start = start
        updated.end = end
        onChange(updated)
    }
}
