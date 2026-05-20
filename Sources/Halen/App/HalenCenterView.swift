import SwiftUI
import Observation

/// The plugin marketplace / control center shown when the user clicks the menubar icon.
/// Native materials, category-grouped plugin cards, per-plugin toggles, footer with
/// permission and quit actions.
enum CenterNav: Equatable {
    case marketplace
    case plugin(String)
    case settings
}

struct HalenCenterView: View {
    @Bindable var state: AppState
    let registry: PluginRegistry
    @Bindable var inferenceSettings: InferenceSettings
    let router: RouterInferenceClient
    @Bindable var modelDownloader: ModelDownloader
    /// Optional — only present once `AppCoordinator.startObservers()` has run
    /// (which happens after Accessibility is granted). The Settings card hides
    /// the WS section while it's nil to avoid a half-rendered control.
    let webSocketBridge: WebSocketBridge?
    /// Owned by AppCoordinator so its observable status survives the menubar
    /// popup closing — passed through to SettingsView's startup card.
    @Bindable var launchAtLogin: LaunchAtLoginController
    /// Backs the Plugin Store modal. App-scoped (AppCoordinator) so a fetched
    /// registry and in-progress install survive the menubar popup closing.
    @Bindable var storeModel: PluginStoreModel
    @State private var nav: CenterNav = .marketplace
    @State private var showingStore = false

    var body: some View {
        ZStack {
            switch nav {
            case .marketplace:
                listScreen
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .plugin(let id):
                if let plugin = registry.plugins.first(where: { $0.id == id }) {
                    PluginDetailContainer(plugin: plugin, onBack: { back() }) {
                        plugin.makeDetailView()
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            case .settings:
                SettingsView(
                    state: state,
                    inferenceSettings: inferenceSettings,
                    router: router,
                    modelDownloader: modelDownloader,
                    webSocketBridge: webSocketBridge,
                    launchAtLogin: launchAtLogin,
                    onBack: { back() }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 380)
        .frame(minHeight: 280, maxHeight: 560)
        .background(.regularMaterial)
        .sheet(isPresented: $showingStore) {
            PluginStoreView(
                registry: registry,
                model: storeModel,
                onClose: { showingStore = false }
            )
        }
    }

    private func push(_ target: CenterNav) {
        withAnimation(.spring(duration: 0.25)) { nav = target }
    }

    private func back() {
        withAnimation(.spring(duration: 0.25)) { nav = .marketplace }
    }

    private var listScreen: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            pluginStoreItem
            Divider()
            footer
        }
    }

    /// Entry point to the Plugin Store modal. Sits at the end of the dropdown,
    /// just above the Accessibility / Quit footer.
    @ViewBuilder
    private var pluginStoreItem: some View {
        Button {
            showingStore = true
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.halenCobalt.opacity(0.16))
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.halenCobalt)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Plugin Store…")
                        .font(.system(.body, weight: .medium))
                    Text("Browse and install more plugins")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(StoreItemButtonStyle())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            brandMark
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Halen")
                    .font(.system(.headline, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                push(.settings)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var brandMark: some View {
        if let logo = NSImage(named: "HalenLogo") {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            // Fallback if the icon assets aren't bundled yet.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.halenCobalt,
                                 Color(red: 0.00, green: 0.43, blue: 1.00)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "text.cursor")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
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

    /// One flat list of every registered plugin — first-party and external,
    /// in registration order. The per-category grouping/headers were removed:
    /// `PluginCategory` survives on the model (other code reads it, and it
    /// still drives the row tint) but no longer sections the dropdown.
    private var pluginList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(registry.plugins, id: \.id) { plugin in
                    PluginRow(
                        plugin: plugin,
                        isEnabled: Binding(
                            get: { registry.isEnabled(plugin.id) },
                            set: { _ in registry.toggle(plugin.id) }
                        ),
                        onTapBody: {
                            push(.plugin(plugin.id))
                        }
                    )
                }
            }
            .padding(.vertical, 6)
        }
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
    var onTapBody: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Button(action: onTapBody) {
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
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

    private var tint: Color { pluginCategoryTint(plugin.category) }
}

/// Hover-highlight button style for the "Plugin Store…" dropdown row, matching
/// `PluginRow`'s subtle row background.
private struct StoreItemButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((isHovering || configuration.isPressed)
                          ? Color.primary.opacity(0.06) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .onHover { isHovering = $0 }
    }
}
