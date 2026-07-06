import SwiftUI

// MARK: - Brand colour
//
// Halen's signature cobalt blue. Centralised here so a future tweak — or a
// dark-mode-aware variant — is a single edit, not a grep across ~15 files.

extension Color {
    /// Halen's signature cobalt blue. Use for the menubar caret, busy ring,
    /// chat bubbles, and any "this came from Halen" surface.
    ///
    /// Cobalt brand. Use at full saturation for accent strokes/icons; the
    /// 0.18-opacity wash is decorative only — never put body text directly
    /// on it. The wash sits well below WCAG AA contrast for text, so any
    /// glyph rendered over it must use a higher-contrast colour (typically
    /// `.primary` or pure `tint` at full alpha) and treat the wash purely
    /// as a tint surface, not a foreground.
    public static let halenCobalt = Color(red: 0, green: 0.30, blue: 0.99)
}

extension CGColor {
    /// `Color.halenCobalt` for `CALayer` consumers (the overlay's rotating ring).
    public static let halenCobalt = CGColor(red: 0, green: 0.30, blue: 0.99, alpha: 1.0)
}

// MARK: - cardLabel

/// Section header used inside `GlassCard`s across every plugin detail view.
/// Free function so all six detail views share one definition.
@ViewBuilder
public func cardLabel(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
}

// MARK: - sentimentRuleColor

/// Maps the persisted `colorName` of a `SentimentRule` to a concrete `Color`.
/// Lives in the theme file rather than next to the rule type so all colour
/// definitions stay in one place.
public func sentimentRuleColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "red":          return Color(red: 0.92, green: 0.27, blue: 0.27)
    case "orange":       return Color(red: 0.97, green: 0.58, blue: 0.20)
    case "yellow":       return Color(red: 0.93, green: 0.80, blue: 0.20)
    case "blue":         return Color(red: 0.21, green: 0.51, blue: 0.92)
    case "purple":       return Color(red: 0.62, green: 0.36, blue: 0.92)
    case "gray", "grey": return Color(white: 0.55)
    default:             return Color.accentColor
    }
}

// MARK: - GlassCard

/// A glass-styled card used by detail views. Always full-width so cards align
/// vertically regardless of intrinsic content size.
///
/// Honors macOS "Reduce transparency": when the pref is on the
/// `.ultraThinMaterial` fill is swapped for an opaque window-background
/// colour so the card has solid, high-contrast chrome instead of a glassy
/// frosted look. Single point of change here covers every settings card
/// and most plugin detail views.
@MainActor
public struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var prefs = AccessibilityPreferences.shared

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            )
    }

    /// `AnyShapeStyle` so we can return either the translucent material or
    /// a plain opaque `Color` from the same expression. The slightly-tinted
    /// fallback (window background with a hair of white) keeps the card
    /// visually distinct from the dropdown's own background.
    private var cardFill: AnyShapeStyle {
        if prefs.reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(Material.ultraThinMaterial)
    }
}
