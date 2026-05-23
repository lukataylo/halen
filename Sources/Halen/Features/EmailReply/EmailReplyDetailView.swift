import SwiftUI

@MainActor
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
                Text("Halen drafts a reply to the message at your cursor. Inserts it in the reply box, or copies to the clipboard.")
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
                Text("For Gmail or Outlook on the web, select the message text first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
