import SwiftUI

@MainActor
struct EmailReplyDetailView: View {
    /// Persisted default tone for every ⌃⌥E draft. `match` defers to the
    /// per-app Tone Profile (the historical behaviour). Live-read by the
    /// plugin on each fire so this picker takes effect without a relaunch.
    @AppStorage(EmailReply.defaultToneKey) private var defaultToneRaw: String =
        EmailReply.ReplyTone.match.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                howCard
                toneCard
                appsCard
            }
            .padding(12)
        }
    }

    private var toneCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Default tone")
                Picker("", selection: $defaultToneRaw) {
                    ForEach(EmailReply.ReplyTone.allCases, id: \.rawValue) { tone in
                        Text(tone.label).tag(tone.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(toneHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var toneHint: String {
        switch EmailReply.ReplyTone(rawValue: defaultToneRaw) ?? .match {
        case .match:   return "Halen uses the tone you set per-app in Tone Profiles. Default."
        case .formal:  return "Always draft in a formal, professional register."
        case .casual:  return "Always draft in a casual, relaxed register."
        case .concise: return "Always keep replies as short as politely possible."
        case .warm:    return "Always lead with warmth — acknowledge the sender first."
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
