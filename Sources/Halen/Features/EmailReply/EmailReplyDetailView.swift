import SwiftUI

struct EmailReplyDetailView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                howCard
                appsCard
            }
            .padding(12)
        }
    }

    private var howCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("How it works")
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .foregroundStyle(Color.accentColor)
                    Text("Press ⌃⌥E in a mail app")
                        .font(.system(.callout, weight: .medium))
                }
                Text("Halen reads the message you've selected (or the one around your cursor), drafts a reply with the local model, and inserts it at your cursor if you're in the reply box — otherwise it copies the draft to the clipboard so you can paste it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Supported apps")
                Text("Mail · Outlook · Spark · Airmail · Canary · Mimestream")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Browser-based mail (Gmail, Outlook web) isn't auto-detected — select the message text first and the hotkey still works.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
