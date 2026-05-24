import SwiftUI
import AppKit

/// App Store-style modal for browsing, installing, and removing plugins.
///
/// Two sections:
///   - INSTALLED — every registered plugin (first-party built-ins + installed
///     external plugins). Each row has an enable/disable toggle; external
///     plugins additionally get a Remove button.
///   - AVAILABLE — external plugins from the fetched registry that aren't
///     installed, each with an Install button.
///
/// System-native look: an opaque `windowBackgroundColor` window with
/// `StoreCard` (opaque `controlBackgroundColor`) rows. Deliberately *not*
/// the translucent `GlassCard` used in the menubar dropdown — in a
/// standalone window that material vibrancy-samples the desktop wallpaper.
///
/// `@MainActor` so the body can access `registry` / `model` / `plugin.id`
/// (all main-actor-isolated). Without this, GitHub's CI Swift toolchain
/// (stricter than the local one) flagged every property access from the
/// body as a cross-actor reference. SwiftUI views are conventionally
/// main-actor-bound in practice; making it explicit here keeps the build
/// healthy across toolchains.
@MainActor
struct PluginStoreView: View {
    let registry: PluginRegistry
    @Bindable var model: PluginStoreModel
    let onClose: () -> Void

    /// Confirmation target for the Remove flow (external plugins only).
    @State private var pendingRemoval: PendingRemoval?
    @State private var removalError: String?

    private struct PendingRemoval: Identifiable {
        let id: String
        let name: String
        let directory: URL
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    installedSection
                    availableSection
                }
                .padding(14)
            }
        }
        .frame(width: 420)
        .frame(minHeight: 360, maxHeight: 580)
        // Opaque native window background. `.regularMaterial` is translucent
        // — in a standalone window it let the desktop wallpaper bleed through
        // and tint the whole store (a warm wallpaper read as "yellow").
        // `windowBackgroundColor` is the system's own window colour and
        // adapts to light/dark.
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
        .alert("Remove plugin?", isPresented: removalAlertBinding, presenting: pendingRemoval) { target in
            Button("Remove", role: .destructive) {
                if let error = model.remove(id: target.id, directory: target.directory) {
                    removalError = error
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("“\(target.name)” will be removed. This can't be undone.")
        }
        .alert("Couldn't remove plugin",
               isPresented: Binding(get: { removalError != nil },
                                    set: { if !$0 { removalError = nil } })) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.halenCobalt.opacity(0.16))
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.headline)
                    .foregroundStyle(Color.halenCobalt)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Plugin Store")
                    .font(.system(.headline, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Discover and manage plugins")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .accessibilityHint("Close the Plugin Store window.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Installed", count: registry.plugins.count)
            if registry.plugins.isEmpty {
                emptyHint("No plugins installed yet.")
            } else {
                ForEach(registry.plugins, id: \.id) { plugin in
                    InstalledPluginRow(
                        plugin: plugin,
                        isEnabled: Binding(
                            get: { registry.isEnabled(plugin.id) },
                            set: { _ in registry.toggle(plugin.id) }
                        ),
                        onRemove: removeRequest(for: plugin)
                    )
                }
            }
        }
    }

    /// Returns a Remove closure only for external plugins (built-ins can't be
    /// uninstalled — they ship inside the app). `nil` hides the Remove button.
    private func removeRequest(for plugin: any HalenPlugin) -> (() -> Void)? {
        guard let external = plugin as? ExternalPluginAdapter else { return nil }
        return {
            pendingRemoval = PendingRemoval(id: external.id,
                                            name: external.name,
                                            directory: external.pluginDir)
        }
    }

    // MARK: - Available

    @ViewBuilder
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.fetchState {
            case .idle, .loading:
                sectionHeader("Available", count: nil)
                loadingCard
            case .failed(let message):
                sectionHeader("Available", count: nil)
                failureCard(message)
            case .loaded:
                let entries = model.notInstalled
                sectionHeader("Available", count: entries.count)
                if entries.isEmpty {
                    emptyHint("All available plugins are installed.")
                } else {
                    ForEach(entries) { entry in
                        AvailablePluginRow(
                            entry: entry,
                            state: model.state(for: entry),
                            onInstall: { Task { await model.install(entry) } }
                        )
                    }
                }
            }
        }
    }

    private var loadingCard: some View {
        StoreCard {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading available plugins")
        }
    }

    private func failureCard(_ message: String) -> some View {
        StoreCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("Registry unavailable")
                        .font(.callout.weight(.semibold))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityLabel("Try again")
                .accessibilityHint("Refetch the plugin registry.")
            }
        }
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            cardLabel(title)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func emptyHint(_ text: String) -> some View {
        StoreCard {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Installed row

@MainActor
private struct InstalledPluginRow: View {
    let plugin: any HalenPlugin
    @Binding var isEnabled: Bool
    /// Non-nil only for external plugins, which can be uninstalled.
    let onRemove: (() -> Void)?

    var body: some View {
        StoreCard {
            HStack(alignment: .center, spacing: 11) {
                PluginIconBadge(systemName: plugin.icon, tint: tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name)
                            .font(.system(.body, weight: .medium))
                        if onRemove != nil {
                            tag("External")
                        }
                    }
                    Text(plugin.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel("Enable \(plugin.name)")
                        .accessibilityHint(plugin.summary)
                    if let onRemove {
                        Button(role: .destructive, action: onRemove) {
                            Text("Remove")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Remove \(plugin.name)")
                        .accessibilityHint("Uninstall this external plugin.")
                    }
                }
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private var tint: Color { pluginCategoryTint(plugin.category) }
}

// MARK: - Available row

@MainActor
private struct AvailablePluginRow: View {
    let entry: PluginRegistryEntry
    let state: PluginStoreModel.InstallState
    let onInstall: () -> Void

    var body: some View {
        StoreCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 11) {
                    PluginIconBadge(systemName: entry.iconName, tint: tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.system(.body, weight: .medium))
                            if entry.isExampleEntry {
                                tag("Example")
                            }
                        }
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("by \(entry.author) · v\(entry.version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 4)

                    installControl
                }

                if case .failed(let message) = state {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Install failed: \(message)")
                }

                if let source = URL(string: entry.sourceURL) {
                    Button {
                        NSWorkspace.shared.open(source)
                    } label: {
                        Label("View source", systemImage: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View source for \(entry.name)")
                    .accessibilityHint("Open the plugin's source URL in your browser.")
                }
            }
        }
    }

    @ViewBuilder
    private var installControl: some View {
        switch state {
        case .installing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Installing \(entry.name)")
        case .available, .failed:
            Button(action: onInstall) {
                Text(isRetry ? "Retry" : "Install")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.halenCobalt))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRetry ? "Retry installing \(entry.name)" : "Install \(entry.name)")
            .accessibilityHint(isRetry
                               ? "Try installing this plugin again after the previous attempt failed."
                               : "Download and install this plugin.")
        }
    }

    private var isRetry: Bool {
        if case .failed = state { return true }
        return false
    }

    private var tint: Color { pluginCategoryTint(entry.resolvedCategory) }
}

// MARK: - Shared visual helpers

@MainActor
private struct PluginIconBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.18))
            Image(systemName: systemName)
                .font(.headline)
                .foregroundStyle(tint)
        }
        .frame(width: 32, height: 32)
        // Decorative — the store row's name and description carry the
        // semantic load. Announcing "icon" first would clutter the
        // VoiceOver rotor for no information gain.
        .accessibilityHidden(true)
    }
}

/// Opaque card surface for the Plugin Store. The shared `GlassCard` uses
/// `.ultraThinMaterial`, which is translucent — in the store's standalone
/// window it vibrancy-samples the desktop wallpaper and tints every card.
/// `StoreCard` uses the system `controlBackgroundColor` instead: an opaque,
/// light/dark-adaptive native surface that sits cleanly on the window.
@MainActor
private struct StoreCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
    }
}

/// Per-category tint, shared by the Store rows and (via `PluginRow`) the
/// menubar list. Category no longer groups the UI — it's purely a colour cue.
func pluginCategoryTint(_ category: PluginCategory) -> Color {
    switch category {
    case .writing:      return Color(red: 0.20, green: 0.55, blue: 0.96)
    case .voice:        return Color(red: 0.93, green: 0.31, blue: 0.55)
    case .scheduling:   return Color(red: 0.97, green: 0.60, blue: 0.20)
    case .focus:        return Color(red: 0.62, green: 0.36, blue: 0.92)
    case .productivity: return Color(red: 0.20, green: 0.74, blue: 0.45)
    }
}
