import SwiftUI

/// Shell view rendered when the user taps a plugin in the marketplace. Holds the
/// back-button header and renders the plugin's own detail content underneath.
/// Uses native glass materials throughout.
@MainActor
struct PluginDetailContainer<Content: View>: View {
    let plugin: any HalenPlugin
    let onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    // Semantic fonts so Larger Accessibility Sizes scales the back
                    // affordance; size: 12 ignored that and stayed pixel-fixed.
                    Image(systemName: "chevron.left")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                    Text("Plugins")
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to plugins")
            .accessibilityHint("Returns to the plugin list.")

            Spacer()

            PluginCategoryBadge(plugin: plugin)
        }
        .overlay(
            HStack(spacing: 8) {
                // The plugin icon is paired with the plugin name right next to
                // it, so the symbol itself is decorative for VoiceOver.
                Image(systemName: plugin.icon)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text(plugin.name)
                    .font(.system(.callout, weight: .semibold))
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

@MainActor
struct PluginCategoryBadge: View {
    let plugin: any HalenPlugin

    var body: some View {
        // Semantic .caption2 so the badge respects Larger Accessibility Sizes;
        // the visual weight is still small but it scales with the user's setting.
        Text(plugin.category.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                    )
            )
    }
}

// `GlassCard` and the shared `cardLabel` helper now live in App/Theme/HalenTheme.swift.
