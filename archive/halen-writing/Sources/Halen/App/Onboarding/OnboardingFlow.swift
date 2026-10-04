import SwiftUI
import AppKit

/// First-run setup walkthrough. Three steps in a fixed-size floating
/// window, glassmorphic chrome to match the menubar dropdown:
///
/// 1. **Welcome** — what Halen is + the three things it does, on one screen.
/// 2. **Choose** — toggle list of plugins, grouped by category.
/// 3. **Permissions** — Accessibility + Input Monitoring with an illustration.
///    Mic / Calendar / Speech / Notifications are asked just-in-time when
///    the user turns the related plugin on, so they don't clutter setup.
///
/// Re-runnable from Settings → About → "Run setup again."
@MainActor
struct OnboardingFlow: View {
    /// The plugin registry the flow toggles against. Same instance the
    /// menubar dropdown uses, so any choice made here is the live state.
    let registry: PluginRegistry
    /// Called when the user reaches Done or hits Skip.
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var permissions = SystemPermissionsModel()
    /// Honors macOS "Reduce transparency": when on we swap the four
    /// `.regularMaterial` surfaces in this flow (window chrome + three
    /// content cards) for opaque colours.
    @State private var prefs = AccessibilityPreferences.shared

    private enum Step: Int, CaseIterable {
        case welcome, choose, permissions
    }

    var body: some View {
        ZStack {
            // Glassmorphic chrome — `.regularMaterial` gives the standard
            // macOS frosted-panel look (less see-through than the previous
            // `.ultraThinMaterial`, which was reading more like a tinted
            // sheet of plastic than glass). Under "Reduce transparency"
            // we drop to the opaque window background so onboarding text
            // sits on a high-contrast surface.
            Color.clear.adaptiveMaterial(.regularMaterial)
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                footer
            }
        }
        .frame(width: 540, height: 440)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    // MARK: - Header (centered progress dots)

    private var header: some View {
        // Centered dots only — the window's native close button (top-left
        // traffic light) is the dismiss affordance, so a separate Skip
        // button up here was redundant.
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue
                          ? Color.accentColor
                          : Color.secondary.opacity(0.22))
                    .frame(width: s.rawValue == step.rawValue ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.22), value: step)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:     welcomeStep
        case .choose:      chooseStep
        case .permissions: permissionsStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            // Hero mark, modest size so the feature rows have room.
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.halenCobalt.opacity(0.18), Color.halenCobalt.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 72, height: 72)
                if let img = NSImage(named: "HalenLogo") {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                }
            }

            VStack(spacing: 4) {
                Text("Writing help, on your Mac.")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Quietly checks what you type. Stays local.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Three feature rows inside a glass card.
            VStack(spacing: 0) {
                featureRow(icon: "exclamationmark.bubble.fill",
                           tint: Color(red: 0.91, green: 0.30, blue: 0.24),
                           title: "Tone",
                           body: "Catches angry-sounding messages before you send.")
                Divider().opacity(0.3).padding(.leading, 44)
                featureRow(icon: "text.magnifyingglass",
                           tint: Color(red: 0.82, green: 0.55, blue: 0.05),
                           title: "Clarity",
                           body: "Flags passive voice and run-on sentences.")
                Divider().opacity(0.3).padding(.leading, 44)
                featureRow(icon: "sparkles",
                           tint: Color.accentColor,
                           title: "Quick Ask",
                           body: "⌃H opens a palette. Ask anything.")
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    /// Card fill: translucent material by default, opaque control colour
    /// when "Reduce transparency" is on. Returns `AnyShapeStyle` so it can
    /// feed `RoundedRectangle.fill(_:)` for either branch.
    private var cardFill: AnyShapeStyle {
        if prefs.reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(Material.regularMaterial)
    }

    private func featureRow(icon: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose what's on.")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Toggle any of these in Settings later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(registry.plugins, id: \.id) { plugin in
                        pluginRow(plugin)
                        if plugin.id != registry.plugins.last?.id {
                            Divider().opacity(0.25).padding(.leading, 38)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator.opacity(0.3), lineWidth: 0.5)
                )
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func pluginRow(_ plugin: any HalenPlugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: plugin.icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name)
                    .font(.callout.weight(.medium))
                Text(plugin.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { registry.isEnabled(plugin.id) },
                set: { _ in registry.toggle(plugin.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("Enable \(plugin.name)")
            .accessibilityHint(plugin.summary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            // Hero illustration — large layered SF Symbol with a soft
            // cobalt backdrop. Anchors the screen.
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 78, height: 78)

            VStack(spacing: 3) {
                Text("Allow Halen to help.")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Two permissions to read text and run shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                permissionRow(.accessibility,
                              title: "Accessibility",
                              body: "Read text near your cursor.")
                Divider().opacity(0.3).padding(.leading, 40)
                permissionRow(.inputMonitoring,
                              title: "Input Monitoring",
                              body: "Run Quick Ask and other shortcuts.")
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func permissionRow(_ kind: SystemPermission, title: String, body: String) -> some View {
        let grant = permissions.grants[kind] ?? .checking
        let granted = (grant == .granted)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((granted ? Color.green : Color.orange).opacity(0.18))
                Image(systemName: granted ? "checkmark" : kind.iconName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(granted ? Color.green : Color.orange)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(granted ? "Granted." : body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Open") {
                    kind.openSystemSettings()
                }
                .controlSize(.small)
                .accessibilityLabel("Open \(title) settings")
                .accessibilityHint("Opens the System Settings pane where you can grant this permission.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    if let prev = Step(rawValue: step.rawValue - 1) {
                        withAnimation(.easeInOut(duration: 0.18)) { step = prev }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                // Explicit label/hint because the auto-label is just "Back"
                // with no context — VoiceOver users hearing only the word
                // mid-flow can't tell what they're going back to.
                .accessibilityLabel("Back")
                .accessibilityHint("Return to the previous setup step.")
            }
            Spacer()
            if step == .permissions {
                Button("Done", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Done")
                    .accessibilityHint("Finish setup and close this window.")
            } else {
                Button("Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) {
                        withAnimation(.easeInOut(duration: 0.18)) { step = next }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Continue")
                .accessibilityHint("Advance to the next setup step.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }
}

// `SystemPermission.iconName` already exists on the type (used by
// SettingsView's Permissions row); the onboarding view re-uses it.
