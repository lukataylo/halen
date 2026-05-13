import SwiftUI
import Observation

/// The plugin marketplace / control center shown when the user clicks the menubar icon.
/// Native materials, category-grouped plugin cards, per-plugin toggles, footer with
/// permission and quit actions.
struct HalenCenterView: View {
    @Bindable var state: AppState
    let registry: PluginRegistry

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .frame(minHeight: 280, maxHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.36, green: 0.42, blue: 0.95),
                                     Color(red: 0.62, green: 0.33, blue: 0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                Image(systemName: "text.cursor")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Halen")
                    .font(.system(.headline, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        switch state.permissionStatus {
        case .unknown: return "Checking permissions…"
        case .denied:  return "Accessibility permission required"
        case .granted:
            let active = registry.activeCount
            let total = registry.plugins.count
            if total == 0 { return "Ready" }
            return "\(active) of \(total) plugin\(total == 1 ? "" : "s") active"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.permissionStatus != .granted {
            permissionEmptyState
        } else if registry.plugins.isEmpty {
            noPluginsEmptyState
        } else {
            pluginList
        }
    }

    private var permissionEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Accessibility access required")
                    .font(.system(.callout, weight: .semibold))
                Text("Halen needs to read text near your cursor and apply corrections. All processing happens locally.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            Button("Open Accessibility Settings") {
                AXPermissions.openSettings()
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var noPluginsEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No plugins registered yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var pluginList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(registry.grouped.enumerated()), id: \.offset) { _, group in
                    let (category, plugins) = group
                    sectionHeader(category)
                    ForEach(plugins, id: \.id) { plugin in
                        PluginRow(
                            plugin: plugin,
                            isEnabled: Binding(
                                get: { registry.isEnabled(plugin.id) },
                                set: { _ in registry.toggle(plugin.id) }
                            )
                        )
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ category: PluginCategory) -> some View {
        Text(category.label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                AXPermissions.openSettings()
            } label: {
                Label("Accessibility", systemImage: "checkmark.shield")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Plugin Row

struct PluginRow: View {
    let plugin: any HalenPlugin
    @Binding var isEnabled: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            iconBadge

            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name)
                    .font(.system(.body, weight: .medium))
                Text(plugin.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.18))
            Image(systemName: plugin.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 32, height: 32)
    }

    private var tint: Color {
        switch plugin.category {
        case .writing:      return Color(red: 0.20, green: 0.55, blue: 0.96)
        case .voice:        return Color(red: 0.93, green: 0.31, blue: 0.55)
        case .scheduling:   return Color(red: 0.97, green: 0.60, blue: 0.20)
        case .focus:        return Color(red: 0.62, green: 0.36, blue: 0.92)
        case .productivity: return Color(red: 0.20, green: 0.74, blue: 0.45)
        }
    }
}
