import SwiftUI

// MARK: - Brand colour
//
// Halen's signature cobalt blue. Centralised here so a future tweak — or a
// dark-mode-aware variant — is a single edit, not a grep across ~15 files.

extension Color {
    /// Halen's signature cobalt blue. Use for the menubar caret, busy ring,
    /// chat bubbles, and any "this came from Halen" surface.
    static let halenCobalt = Color(red: 0, green: 0.30, blue: 0.99)
}

extension CGColor {
    /// `Color.halenCobalt` for `CALayer` consumers (the overlay's rotating ring).
    static let halenCobalt = CGColor(red: 0, green: 0.30, blue: 0.99, alpha: 1.0)
}

// MARK: - cardLabel

/// Section header used inside `GlassCard`s across every plugin detail view.
/// Free function so all six detail views share one definition.
@ViewBuilder
func cardLabel(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
}

// MARK: - sentimentRuleColor

/// Maps the persisted `colorName` of a `SentimentRule` to a concrete `Color`.
/// Lives in the theme file rather than next to the rule type so all colour
/// definitions stay in one place.
func sentimentRuleColor(_ name: String) -> Color {
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
@MainActor
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

// MARK: - HalenChatBubble + TypingDots

/// Cobalt-blue chat bubble used by Meeting Prep (and reusable by other
/// plugins). Avatar on the left, bubble content on the right. Bullets in the
/// body get rendered as a clean list; loading state animates three dots in
/// the bubble.
@MainActor
struct HalenChatBubble: View {
    let headline: String
    let content: String?
    let isLoading: Bool
    let onCopy: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            bubble
            Spacer(minLength: 0)
        }
    }

    private var avatar: some View {
        Group {
            if let img = NSImage(named: "HalenLogo") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(Color.halenCobalt)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            if isLoading {
                TypingDots(color: .white)
                    .padding(.vertical, 6)
            } else if let content, !content.isEmpty {
                bullets(from: content)
                if let onCopy {
                    HStack {
                        Spacer()
                        Button(action: onCopy) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 4, bottomLeading: 14, bottomTrailing: 14, topTrailing: 14)
            )
            .fill(Color.halenCobalt)
        )
        .shadow(color: Color.halenCobalt.opacity(0.30), radius: 10, x: 0, y: 4)
    }

    private func bullets(from text: String) -> some View {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { stripBullet(from: $0) }

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stripBullet(from line: String) -> String {
        var l = line
        for prefix in ["- ", "* ", "• ", "•", "*", "-"] {
            if l.hasPrefix(prefix) {
                l = String(l.dropFirst(prefix.count))
                break
            }
        }
        return l.trimmingCharacters(in: .whitespaces)
    }
}

/// Three pulsing dots, iMessage-style. Used inside `HalenChatBubble` while a
/// Gemma response is in flight.
@MainActor
struct TypingDots: View {
    let color: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: 6) {
            dot(delay: 0)
            dot(delay: 0.18)
            dot(delay: 0.36)
        }
        .onAppear { animating = true }
    }

    private func dot(delay: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(animating ? 1.0 : 0.3)
            .scaleEffect(animating ? 1.0 : 0.65)
            .animation(
                .easeInOut(duration: 0.6)
                    .repeatForever()
                    .delay(delay),
                value: animating
            )
    }
}
