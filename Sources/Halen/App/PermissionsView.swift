import SwiftUI
import HalenKit
import HalenPluginAPI

/// The one permissions screen. Everything that can touch your text, your
/// mic, or your screen is on this page: the macOS (TCC) permissions Halen
/// itself holds, then every plugin with every capability it declared, each
/// individually revocable. This screen *is* the product's brand — you can
/// see exactly what touches what.
@MainActor
struct PermissionsView: View {
    let coordinator: AppCoordinator
    @Bindable var broker: PermissionBroker
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    systemCard
                    pluginCards
                    footnote
                }
                .padding(14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text("Permissions")
                .font(.system(.headline, weight: .semibold))
            Spacer()
            Button {
                broker.system.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Re-check system permissions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - System (TCC) permissions

    private var systemCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("macOS permissions")
                ForEach(SystemPermission.allCases) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: permission.iconName)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(permission.purpose)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        grantBadge(broker.system.grants[permission] ?? .checking,
                                   permission: permission)
                    }
                }
            }
        }
        .onAppear { broker.system.refresh() }
    }

    @ViewBuilder
    private func grantBadge(_ grant: PermissionGrant, permission: SystemPermission) -> some View {
        switch grant {
        case .granted:
            Label("On", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .checking:
            Text("…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .denied:
            Button("Open Settings") { permission.openSystemSettings() }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
        case .notRequested:
            Button("Ask") {
                Task { _ = await broker.request(permission) }
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Per-plugin capabilities

    @ViewBuilder
    private var pluginCards: some View {
        ForEach(coordinator.allManifests, id: \.id) { manifest in
            if !manifest.declaredCapabilityStrings.isEmpty {
                pluginCard(manifest)
            }
        }
    }

    private func pluginCard(_ manifest: PluginManifest) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: manifest.icon ?? "puzzlepiece.extension")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.halenCobalt)
                    Text(manifest.name)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if !coordinator.registry.isEnabled(manifest.id) {
                        Text("Off")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }

                ForEach(manifest.declaredCapabilities) { capability in
                    capabilityRow(capability, manifest: manifest)
                }

                // Capabilities this build doesn't recognise (a newer or
                // hand-written manifest). Ungrantable, but never hidden —
                // hiding a declared capability would defeat the screen.
                let unknown = manifest.declaredCapabilityStrings.filter {
                    Capability(rawValue: $0) == nil
                }
                ForEach(unknown, id: \.self) { raw in
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .frame(width: 20)
                        Text("\(raw) — unknown capability, never granted")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private func capabilityRow(_ capability: Capability, manifest: PluginManifest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: capability.iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(capability.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(capability.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { broker.isGranted(capability, manifest: manifest) },
                set: { granted in
                    broker.setGranted(granted, capability: capability, pluginId: manifest.id)
                    // In-process plugins capture their services at
                    // construction — rebuild so the context matches the
                    // grant table. External plugins re-check per RPC call.
                    coordinator.reloadPlugin(id: manifest.id)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("\(capability.displayName) for \(manifest.name)")
        }
    }

    private var footnote: some View {
        Text("Capabilities are declared up front in each plugin's manifest and enforced by the host. Revoking one takes effect immediately; the plugin keeps running with that door closed.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
