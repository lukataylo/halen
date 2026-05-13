import SwiftUI
import AppKit

struct MeetingPrepDetailView: View {
    @Bindable var state: MeetingPrepState
    let onGenerateNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                permissionsCard
                nextEventCard
                generateCard
                if !state.recentBriefings.isEmpty {
                    briefingsCard
                }
            }
            .padding(12)
        }
    }

    // MARK: - Cards

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Permissions")
                permissionRow(label: "Calendar", ok: state.calendarAuthorized)
                permissionRow(label: "Notifications", ok: state.notificationsAuthorized)
            }
        }
    }

    private var nextEventCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Next event")
                if let title = state.nextEventTitle, let start = state.nextEventStart {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                            Text(relative(start))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    Text("Nothing in the next 24 hours.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var generateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Generate now")
                Text("Bypass the 15-minute trigger and brief the next event immediately. Result lands on your clipboard.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onGenerateNow) {
                    Label("Brief next event", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!state.calendarAuthorized || state.nextEventTitle == nil)
            }
        }
    }

    private var briefingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Recent briefings")
                ForEach(state.recentBriefings) { brief in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(brief.title)
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(relative(brief.timestamp))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(brief.body, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Text(brief.body)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if brief.id != state.recentBriefings.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Bits

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func permissionRow(label: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color(red: 0.20, green: 0.78, blue: 0.45) : Color.orange)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(.callout))
            Spacer()
            Text(ok ? "Granted" : "Pending")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
