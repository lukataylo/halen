import SwiftUI

/// Dark pill shown near the caret while dictation is recording.
/// Animated audio-level visualiser in the middle; Stop (commit) and Cancel
/// (discard) buttons on the right.
@MainActor
struct VoiceListeningIndicator: View {
    @Bindable var state: VoiceDictationState
    let onStop: () -> Void
    let onCancel: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            // Recording-dot indicator
            ZStack {
                Circle()
                    .fill(Color.halenCobalt.opacity(0.4))
                    .scaleEffect(pulse ? 1.7 : 1.0)
                    .opacity(pulse ? 0 : 1)
                Circle()
                    .fill(Color.halenCobalt)
                    .frame(width: 9, height: 9)
            }
            .frame(width: 20, height: 20)

            // Live visualiser
            VoiceWaveformView(levels: state.audioLevels)
                .frame(maxWidth: .infinity)
                .frame(height: 28)

            // Stop = commit transcript
            CircleIconButton(
                systemImage: "stop.fill",
                tint: Color.halenCobalt,
                action: onStop
            )

            // Cancel = discard
            CircleIconButton(
                systemImage: "xmark",
                tint: Color.secondary,
                action: onCancel
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color(white: 0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
        )
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Simple bar-style audio visualiser. Each bar's height tracks one entry in
/// `levels` (a rolling window of recent RMS amplitudes). New samples push
/// the window left so the most recent audio is on the right.
@MainActor
struct VoiceWaveformView: View {
    let levels: [Float]
    private let barCount = 28
    private let accent = Color.halenCobalt   // chart bars use the brand colour

    var body: some View {
        GeometryReader { geo in
            let displayed = Array(levels.suffix(barCount))
            let spacing: CGFloat = 3
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<displayed.count, id: \.self) { i in
                    let level = CGFloat(displayed[i])
                    let h = max(2, level * geo.size.height)
                    Capsule()
                        .fill(accent.opacity(0.35 + Double(level) * 0.65))
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
}

/// Round monochrome icon button used in the listening pill.
@MainActor
private struct CircleIconButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(tint.opacity(hovering ? 0.95 : 0.75))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Detail view shown when the user taps Voice Dictation in the marketplace.
@MainActor
struct VoiceDictationDetailView: View {
    @Bindable var state: VoiceDictationState

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                hotkeyCard
                permissionsCard
                engineCard
            }
            .padding(12)
        }
        .onAppear { state.refreshPermissions() }
    }

    // MARK: - Cards

    private var hotkeyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardLabel("Hotkey")
                HStack(spacing: 6) {
                    KeyCap(label: "\u{2325}")
                    KeyCap(label: "\u{2318}")
                    KeyCap(label: "H")
                    Spacer()
                }
                Text("Press to start. Press again to stop and insert the transcript at your cursor.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Permissions")
                permissionRow(label: "Microphone", state: state.micPermission)
                permissionRow(label: "Speech recognition", state: state.speechPermission)
                Button("Refresh") { state.refreshPermissions() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Color.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var engineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                cardLabel("Engine")
                HStack(spacing: 10) {
                    statusDot(for: state.engine)
                    Text(engineLabel)
                        .font(.system(.callout))
                    Spacer()
                }
                if let transcript = state.lastTranscript, !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last transcript")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(transcript)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Transcription runs locally via Apple's on-device speech recognition. Audio never leaves this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Bits

    private func permissionRow(label: String, state: PermissionState) -> some View {
        HStack(spacing: 8) {
            statusDot(for: state)
            Text(label)
                .font(.system(.callout))
            Spacer()
            Text(stateLabel(state))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var engineLabel: String {
        switch state.engine {
        case .idle:          return "Idle"
        case .listening:     return "Listening…"
        case .transcribing:  return "Transcribing…"
        }
    }

    private func stateLabel(_ s: PermissionState) -> String {
        switch s {
        case .notDetermined: return "Will request on first use"
        case .granted:       return "Granted"
        case .denied:        return "Denied — check System Settings"
        }
    }

    private func statusDot(for s: PermissionState) -> some View {
        let color: Color
        switch s {
        case .granted:       color = Color(red: 0.20, green: 0.78, blue: 0.35)
        case .denied:        color = Color.red
        case .notDetermined: color = Color.orange
        }
        return statusDot(color: color)
    }

    private func statusDot(for engine: VoiceDictationState.Engine) -> some View {
        let color: Color
        switch engine {
        case .idle:         color = Color.secondary
        case .listening:    color = Color.pink
        case .transcribing: color = Color.orange
        }
        return statusDot(color: color)
    }

    private func statusDot(color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.3)).frame(width: 14, height: 14)
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }
}

/// Small monospaced "key cap" pill used to render a shortcut.
@MainActor
private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.background.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                    )
            )
    }
}
