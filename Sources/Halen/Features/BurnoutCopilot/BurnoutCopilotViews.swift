import SwiftUI

// MARK: - Popup

struct BurnoutCopilotPopup: View {
    let message: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.0, green: 0.30, blue: 0.99))
                Text("Take 10?")
                    .font(.system(.title3, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Halen can drop a 10-min block on your calendar now and trigger your \"Halen Focus\" Shortcut if you have one.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not now", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Spacer()
                Button {
                    onAccept()
                } label: {
                    Label("Block it in", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(red: 0.0, green: 0.30, blue: 0.99).opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Detail view

struct BurnoutCopilotDetailView: View {
    @Bindable var state: BurnoutState
    let onForceEvaluate: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                signalsCard
                toneCard
                calendarCard
                evaluateCard
            }
            .padding(12)
        }
    }

    // MARK: - Cards

    private var signalsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Signals")
                signalRow(
                    label: "Distraction time",
                    detail: "\(state.distractionMinutes) / \(state.distractionThreshold) min in last 2h",
                    tripped: state.signalA,
                    progress: Double(state.distractionMinutes) / Double(max(1, state.distractionThreshold))
                )
                signalRow(
                    label: "Sharp tone trend",
                    detail: "\(state.toneSharpCount) / \(state.toneTripThreshold) of last 10",
                    tripped: state.signalB,
                    progress: Double(state.toneSharpCount) / Double(max(1, state.toneTripThreshold))
                )
                signalRow(
                    label: "Calendar load",
                    detail: state.calendarHasAccess
                        ? "\(state.nextFourHourEvents) events / next 4h\(state.hasBackToBackSoon ? "  ·  back-to-back soon" : "")"
                        : "Calendar access needed",
                    tripped: state.signalC,
                    progress: Double(state.nextFourHourEvents) / Double(max(1, state.calendarTripThreshold))
                )
            }
        }
    }

    private var toneCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Tone history")
                HStack(spacing: 4) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, t in
                        Circle()
                            .fill(t == .sharp ? Color(red: 0.92, green: 0.27, blue: 0.27) : Color.green)
                            .frame(width: 10, height: 10)
                            .opacity(0.8)
                    }
                    Spacer()
                }
                Text("Last \(state.toneSamples.count) classified messages. Red = sharp / irritated, green = calm.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var samples: [ToneTrendTracker.Tone] {
        let padded = state.toneSamples + Array(repeating: ToneTrendTracker.Tone.calm, count: max(0, 10 - state.toneSamples.count))
        return Array(padded.suffix(10))
    }

    private var calendarCard: some View {
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
                            Text(relativeStart(start))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    Text("Nothing in the next 4 hours.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func relativeStart(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var evaluateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Force evaluation")
                Text("Re-runs all three signals immediately and surfaces the popup if ≥2 trip — useful for demos.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onForceEvaluate) {
                    Label("Evaluate now", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
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

    private func signalRow(label: String, detail: String, tripped: Bool, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tripped ? Color(red: 0.97, green: 0.58, blue: 0.20) : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(.callout, weight: .medium))
                Spacer()
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.06))
                    Capsule()
                        .fill(tripped ? Color(red: 0.97, green: 0.58, blue: 0.20) : Color(red: 0.36, green: 0.50, blue: 0.95))
                        .frame(width: max(2, min(1.0, progress) * geo.size.width))
                }
            }
            .frame(height: 4)
        }
    }
}
