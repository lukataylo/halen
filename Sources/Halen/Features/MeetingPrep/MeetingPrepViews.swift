import SwiftUI
import AppKit

struct MeetingPrepDetailView: View {
    @Bindable var state: MeetingPrepState
    let onGenerateNow: () -> Void
    let onRequestAccess: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                heroCard
                briefingBubble
                permissionsCard
                if !state.recentBriefings.isEmpty {
                    historyCard
                }
            }
            .padding(12)
        }
    }

    // MARK: - Hero card (mascot + next event)

    private var heroCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                mascot
                heroBody
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var mascot: some View {
        let badgeSize: CGFloat = 56
        return Group {
            if let logo = NSImage(named: "HalenLogo") {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: badgeSize, height: badgeSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color(red: 0, green: 0.30, blue: 0.99).opacity(0.4), radius: 12, x: 0, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0, green: 0.30, blue: 0.99))
                    .frame(width: badgeSize, height: badgeSize)
                    .overlay(
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
    }

    @ViewBuilder
    private var heroBody: some View {
        if !state.calendarAuthorized {
            heroNoAccess
        } else if let title = state.nextEventTitle, let start = state.nextEventStart {
            heroEvent(title: title, start: start)
        } else {
            heroNoEvents
        }
    }

    private var heroNoAccess: some View {
        VStack(spacing: 8) {
            Text("Show me your calendar")
                .font(.system(.title3, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Halen needs read access to your events to brief you 15 minutes before each one. Calendar data never leaves this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            Button("Grant calendar access") { onRequestAccess() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 6)
        }
    }

    private func heroEvent(title: String, start: Date) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text("Next up")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.title3, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                Text(relative(start))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0, green: 0.30, blue: 0.99))
            }

            if !state.nextEventAttendees.isEmpty {
                attendeesStrip
            }

            Button {
                onGenerateNow()
            } label: {
                Label(generateLabel, systemImage: generateIcon)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isGenerating)
            .padding(.top, 2)
        }
    }

    private var heroNoEvents: some View {
        VStack(spacing: 8) {
            Text("Nothing on your plate")
                .font(.system(.title3, weight: .semibold))
            Text("No events in the next 24 hours. Halen will pop a briefing into your clipboard 15 minutes before your next meeting.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    private var attendeesStrip: some View {
        let names = state.nextEventAttendees.prefix(5)
        let more = state.nextEventAttendees.count - names.count
        return VStack(spacing: 4) {
            Text("Attendees")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                ForEach(Array(names), id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.12))
                        )
                        .lineLimit(1)
                }
                if more > 0 {
                    Text("+\(more)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Briefing chat bubble

    @ViewBuilder
    private var briefingBubble: some View {
        switch state.generation {
        case .idle:
            EmptyView()
        case .generating(let title):
            HalenChatBubble(headline: "Briefing \(title)…", content: nil, isLoading: true, onCopy: nil)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)),
                    removal: .opacity
                ))
        case .success(let title):
            HalenChatBubble(
                headline: title,
                content: latestBriefingBody,
                isLoading: false,
                onCopy: latestBriefingBody.map { snapshot in
                    {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snapshot, forType: .string)
                    }
                }
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            ))
        case .error(let message):
            errorBubble(message: message)
        }
    }

    private var latestBriefingBody: String? {
        state.recentBriefings.first?.body
    }

    private func errorBubble(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't generate a briefing")
                    .font(.system(.callout, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Permissions")
                permissionRow(label: "Calendar",
                              ok: state.calendarAuthorized,
                              action: state.calendarAuthorized ? nil : onRequestAccess)
                permissionRow(label: "Notifications",
                              ok: state.notificationsAuthorized,
                              action: nil)
            }
        }
    }

    private func permissionRow(label: String, ok: Bool, action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color(red: 0.20, green: 0.78, blue: 0.45) : Color.orange)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(.callout))
            Spacer()
            if ok {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let action {
                Button("Request", action: action)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Color(red: 0, green: 0.30, blue: 0.99))
            } else {
                Text("Pending")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Recent briefings")
                ForEach(state.recentBriefings) { brief in
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
                    if brief.id != state.recentBriefings.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var isGenerating: Bool {
        if case .generating = state.generation { return true } else { return false }
    }

    private var generateLabel: String {
        switch state.generation {
        case .generating: return "Briefing in progress…"
        case .success:    return "Brief again"
        default:          return "Brief this event now"
        }
    }

    private var generateIcon: String {
        switch state.generation {
        case .success: return "arrow.clockwise"
        default:       return "sparkles"
        }
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - HalenChatBubble

/// Cobalt-blue chat bubble used by Meeting Prep (and reusable by other plugins).
/// Avatar on the left, bubble content on the right. Bullets in the body get
/// rendered as a clean list; loading state animates three dots in the bubble.
struct HalenChatBubble: View {
    let headline: String
    let content: String?
    let isLoading: Bool
    let onCopy: (() -> Void)?

    private let cobalt = Color(red: 0, green: 0.30, blue: 0.99)

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
                Rectangle().fill(cobalt)
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
                                .background(
                                    Capsule().fill(.white.opacity(0.15))
                                )
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
            .fill(cobalt)
        )
        .shadow(color: cobalt.opacity(0.30), radius: 10, x: 0, y: 4)
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

// MARK: - TypingDots

/// Three pulsing dots, iMessage-style.
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
