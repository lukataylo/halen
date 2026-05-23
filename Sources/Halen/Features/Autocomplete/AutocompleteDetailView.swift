import SwiftUI

@MainActor
struct AutocompleteDetailView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                howCard
                limitsCard
            }
            .padding(12)
        }
    }

    private var howCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("How it works")
                HStack(spacing: 8) {
                    Image(systemName: "text.append")
                        .foregroundStyle(Color.accentColor)
                    Text("Pause while typing")
                        .font(.system(.callout, weight: .medium))
                }
                Text("Pause typing to see suggestions in gray. Press Tab to accept.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var limitsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Known limits")
                Text("Suggestions appear as a floating overlay. Alignment is best in Mail, Notes, and TextEdit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
