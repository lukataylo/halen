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

@MainActor
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
    /// Process-wide hotkey conflict tracker. Observed by SettingsView so a
    /// collision detected at plugin startup renders a warning card.
    @Bindable var hotkeyConflicts: HotkeyConflictRegistry
    /// Opens the Plugin Store. It's a standalone window (not a sheet on this
    /// dropdown) so it survives the menubar popover closing — see
    /// `PluginStoreWindowController`.
    let onOpenStore: () -> Void
    /// Re-trigger the first-run setup walkthrough. Wired through to
    /// `AppCoordinator.onboardingWindow.presentAgain()`. Surfaced in
    /// SettingsView's About card.
    let onRunSetupAgain: () -> Void
    /// Sparkle-backed auto-updater. Passed through to SettingsView for
    /// the "Check for Updates" action.
    let updater: UpdaterController
    /// Per-app tone profile editor data. Passed through to SettingsView's
    /// "App tone profiles" card. Both owned at AppCoordinator scope.
    @Bindable var toneProfileStore: AppToneProfileStore
    @Bindable var recentApps: RecentAppsModel
    @State private var nav: CenterNav = .marketplace
    /// Tracks macOS "Reduce motion" / "Reduce transparency" prefs so the
    /// nav transition + dropdown background can adapt without restart.
    @State private var prefs = AccessibilityPreferences.shared

    var body: some View {
        ZStack {
            switch nav {
            case .marketplace:
                listScreen
                    .transition(navTransition(from: .leading))
            case .plugin(let id):
                if let plugin = registry.plugins.first(where: { $0.id == id }) {
                    PluginDetailContainer(plugin: plugin, onBack: { back() }) {
                        plugin.makeDetailView()
                    }
                    .transition(navTransition(from: .trailing))
                }
            case .settings:
                SettingsView(
                    state: state,
                    inferenceSettings: inferenceSettings,
                    router: router,
                    modelDownloader: modelDownloader,
                    webSocketBridge: webSocketBridge,
                    launchAtLogin: launchAtLogin,
                    toneProfileStore: toneProfileStore,
                    recentApps: recentApps,
                    hotkeyConflicts: hotkeyConflicts,
                    onBack: { back() },
                    onRunSetupAgain: onRunSetupAgain,
                    updater: updater
                )
                .transition(navTransition(from: .trailing))
            }
        }
        .frame(width: 380)
        // Taller defaults — the plugin list + footer felt cramped with
        // 280/560. New floor fits the full first-party plugin list without
        // scrolling; new ceiling gives custom rules + external plugins room
        // before the list scrolls on a 13" display.
        .frame(minHeight: 360, maxHeight: 680)
        .adaptiveMaterial(.regularMaterial)
    }

    /// Honors macOS "Reduce motion": swaps the slide+fade navigation
    /// transition for a plain crossfade so the dropdown doesn't slide
    /// content in from a screen edge.
    private func navTransition(from edge: Edge) -> AnyTransition {
        if prefs.reduceMotion {
            return .opacity
        }
        return .move(edge: edge).combined(with: .opacity)
    }

    private func push(_ target: CenterNav) {
        // Under Reduce Motion the spring is replaced with a tight linear
        // fade — no overshoot/bounce, no edge slide (see `navTransition`).
        if prefs.reduceMotion {
            withAnimation(.linear(duration: 0.12)) { nav = target }
        } else {
            withAnimation(.spring(duration: 0.25)) { nav = target }
        }
    }

    private func back() {
        if prefs.reduceMotion {
            withAnimation(.linear(duration: 0.12)) { nav = .marketplace }
        } else {
            withAnimation(.spring(duration: 0.25)) { nav = .marketplace }
        }
    }

    private var listScreen: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Opens the Plugin Store in its own standalone window — kept
            // out of the plugin list so "browse/install plugins" reads as a
            // distinct action, not another plugin row.
            Button(action: onOpenStore) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Plugin Store")

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
            .help("Settings")
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
                    .font(.caption)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// One flat list of every registered plugin — first-party and external,
    /// in registration order. `PluginCategory` survives on the model (other
    /// code reads it, and it still drives the row tint) but no longer
    /// sections the dropdown.
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
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Plugin Row

@MainActor
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
                            .font(.caption)
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
        // Decorative — VoiceOver already reads the plugin's name on the
        // row's primary button; announcing "icon" before that would be
        // noise. The badge tint encodes category visually, not semantically.
        .accessibilityHidden(true)
    }

    private var tint: Color { pluginCategoryTint(plugin.category) }
}
