import SwiftUI

/// The pulsing pill shown near the caret while dictation is recording.
struct VoiceListeningIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.pink.opacity(0.35))
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 1)
                Circle()
                    .fill(Color.pink)
                    .frame(width: 12, height: 12)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Listening")
                    .font(.system(size: 12, weight: .semibold))
                Text("\u{2325}\u{2318}Space to stop")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.pink.opacity(0.25), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Detail view shown when the user taps Voice Dictation in the marketplace.
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
                    KeyCap(label: "Space")
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

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

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
