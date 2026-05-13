import SwiftUI

/// Shell view rendered when the user taps a plugin in the marketplace. Holds the
/// back-button header and renders the plugin's own detail content underneath.
/// Uses native glass materials throughout.
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
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Plugins")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            PluginCategoryBadge(plugin: plugin)
        }
        .overlay(
            HStack(spacing: 8) {
                Image(systemName: plugin.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(plugin.name)
                    .font(.system(.callout, weight: .semibold))
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct PluginCategoryBadge: View {
    let plugin: any HalenPlugin

    var body: some View {
        Text(plugin.category.label)
            .font(.system(size: 10, weight: .semibold))
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

/// A glass-styled card used by detail views. Always full-width so cards align
/// vertically regardless of intrinsic content size.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
    }
}
