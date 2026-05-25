import SwiftUI

/// Observable model that owns the buddy's current expression. Mutated by
/// `AppDelegate` in response to bridge messages; published into SwiftUI.
final class BuddyModel: ObservableObject {
    @Published var expression: Expression = .neutral
}

/// The character itself — a soft gradient orb with a centred glyph that
/// changes with `expression`. Has a subtle bob to feel alive.
struct BuddyView: View {
    @ObservedObject var model: BuddyModel
    let onClick: () -> Void

    @State private var bob: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            tint.opacity(0.95),
                            tint.opacity(0.55)
                        ],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: 90
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(0.55),
                        lineWidth: 1.5
                    )
                )
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)

            Text(glyph)
                .font(.system(size: 44))
                .accessibilityLabel("Halen buddy — \(model.expression.rawValue)")
        }
        .padding(6)
        .offset(y: bob)
        .onAppear { startBob() }
        .animation(.easeInOut(duration: 0.35), value: model.expression)
        .contentShape(Circle())
    }

    private var glyph: String {
        switch model.expression {
        case .neutral:  return "🙂"
        case .happy:    return "😊"
        case .worried:  return "😟"
        case .thinking: return "🤔"
        }
    }

    /// Cobalt → match the Halen brand. Shifts a touch with mood so the
    /// state is readable at a glance even with the glyph in peripheral
    /// vision.
    private var tint: Color {
        switch model.expression {
        case .neutral:  return Color(red: 0.09, green: 0.21, blue: 0.84)
        case .happy:    return Color(red: 0.18, green: 0.55, blue: 0.95)
        case .worried:  return Color(red: 0.76, green: 0.38, blue: 0.22)
        case .thinking: return Color(red: 0.40, green: 0.32, blue: 0.78)
        }
    }

    private func startBob() {
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            bob = -4
        }
    }
}
