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
                Text("When you stop at the end of a line, Halen suggests the next few words in gray ghost text just past your cursor. Press Tab to accept it; any other keystroke dismisses it.")
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
                Text("The ghost text is a floating overlay, not real inline text — macOS can't draw inside another app's text field. Alignment is good in native fields (TextEdit, Notes, Mail) and rougher in Electron and web editors. While a suggestion is visible, Tab is captured to accept it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
