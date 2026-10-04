import SwiftUI

/// Pixel-grid voice indicator shown near the caret while dictation is
/// recording. Deep-black capsule, glowing recording dot on the left, a
/// dotted-matrix waveform in the middle, Stop (commit) and Cancel
/// (discard) buttons on the right.
@MainActor
struct VoiceListeningIndicator: View {
    @Bindable var state: VoiceDictationState
    let onStop: () -> Void
    let onCancel: () -> Void
    @State private var pulse = false
    /// Honors macOS "Reduce motion": the expanding halo behind the
    /// recording dot stays at rest size/opacity rather than pulsing.
    @State private var prefs = AccessibilityPreferences.shared

    var body: some View {
        HStack(spacing: 10) {
            recordingDot
            VoiceWaveformView(levels: state.audioLevels)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            CircleIconButton(
                systemImage: "stop.fill",
                tint: Color.halenCobalt,
                action: onStop
            )
            CircleIconButton(
                systemImage: "xmark",
                tint: Color(white: 0.18),
                action: onCancel
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color(white: 0.03))
                // Single, smaller drop shadow. The earlier cobalt aura
                // (radius 16) read as a faint rectangle because its
                // outer falloff was almost exactly at the NSPanel's
                // rectangular bound — even with the panel oversized,
                // a sub-pixel shadow tail clips visibly there.
                .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 4)
        )
        // Outer padding inside the (deliberately oversized) NSPanel.
        // Padding ≥ 2× shadow radius keeps the shadow falloff well
        // inside the panel bounds so there's no visible rectangular
        // cut-off at its edge.
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .onAppear {
            guard !prefs.reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }

    /// Cobalt recording dot with a soft expanding halo. Inside a 26 pt
    /// circle filled at low alpha so it reads as a "button" without
    /// stealing focus from the waveform.
    private var recordingDot: some View {
        ZStack {
            Circle()
                .fill(Color.halenCobalt.opacity(0.18))
                .frame(width: 26, height: 26)
            Circle()
                .fill(Color.halenCobalt.opacity(0.5))
                .frame(width: 18, height: 18)
                .scaleEffect(prefs.reduceMotion ? 1.0 : (pulse ? 1.55 : 1.0))
                .opacity(prefs.reduceMotion ? 0.55 : (pulse ? 0 : 0.8))
            Circle()
                .fill(Color.halenCobalt)
                .frame(width: 9, height: 9)
                .shadow(color: Color.halenCobalt.opacity(0.85), radius: 4)
        }
        .frame(width: 26, height: 26)
    }
}

/// Dot-matrix audio visualiser. Each column tracks one entry in `levels`
/// (a rolling RMS-amplitude window). The column lights N dots from the
/// vertical centre outward, top + bottom, where N scales with the
/// level. Quiet dots stay faintly visible so the grid is always
/// readable as a grid; loud dots ramp up brightness and gain a glow.
/// A continuous shimmer travels along the centre row so the indicator
/// reads as "listening" even during silence.
@MainActor
struct VoiceWaveformView: View {
    let levels: [Float]
    /// 0…1, advances continuously. Drives the centre-row scanner: the
    /// dot at column `c` brightens when `phase` is near `c/columnCount`.
    @State private var phase: Double = 0
    @State private var prefs = AccessibilityPreferences.shared
    private let columnCount = 32
    private let rowCount = 7   // odd — gives a symmetric centre row
    private let accent = Color.halenCobalt

    var body: some View {
        GeometryReader { geo in
            let displayed = Self.padLevels(Array(levels.suffix(columnCount)),
                                           target: columnCount)
            let dotSize: CGFloat = 3
            let xSpacing = max(0, (geo.size.width - dotSize * CGFloat(columnCount)) / CGFloat(max(1, columnCount - 1)))
            let ySpacing = max(0, (geo.size.height - dotSize * CGFloat(rowCount)) / CGFloat(max(1, rowCount - 1)))
            let centreRow = (rowCount - 1) / 2

            // Bind the ranges locally — without this the nested ForEach
            // picks SwiftUI's `Binding<...>` overload of `ForEach`
            // instead of `Range<Int>` and the body fails to typecheck.
            let columns = Array(0..<columnCount)
            let rows = Array(0..<rowCount)
            HStack(spacing: xSpacing) {
                ForEach(columns, id: \.self) { (col: Int) in
                    let level = CGFloat(displayed[col])
                    // Lit rows = how far we extend from the centre. A
                    // level of 1.0 fills every row; 0.0 only lights the
                    // centre row. +0.5 so quiet input still shows two
                    // rows of dim dots instead of a flatline.
                    let lit = max(0.5, level * CGFloat(centreRow + 1))
                    // Centre-row scanner pulse. `phase` runs 0→1; each
                    // column's contribution peaks when phase passes
                    // through `col/columnCount`. Gaussian-ish falloff
                    // (width ~3 columns) gives a smooth travelling
                    // highlight rather than a hard cursor.
                    let columnPhase = Double(col) / Double(columnCount)
                    let phaseDistance = min(abs(phase - columnPhase),
                                            1 - abs(phase - columnPhase))   // wrap
                    let scanGlow = max(0, 1 - phaseDistance * Double(columnCount) / 3)
                    VStack(spacing: ySpacing) {
                        ForEach(rows, id: \.self) { (row: Int) in
                            let distance = CGFloat(abs(row - centreRow))
                            let on = distance < lit
                            let edgeFalloff = on ? max(0.35, 1 - distance / max(1, lit)) : 0
                            // Centre-row baseline: even when audio is
                            // silent, the centre row tracks `scanGlow`
                            // so the strip never goes fully dead.
                            let isCentre = (row == centreRow)
                            // Centre row layers an always-on scanner
                            // pulse over its audio-driven brightness;
                            // off-centre rows are purely auditory with
                            // a low baseline so the grid is readable.
                            let baseAlpha: Double = isCentre
                                ? max(on ? Double(edgeFalloff) : 0.18,
                                      0.18 + scanGlow * 0.7)
                                : (on ? Double(edgeFalloff) : 0.10)
                            // Glow scales with brightness — the
                            // scanner's travelling highlight gets the
                            // same haze as a loud-syllable peak.
                            let glowAlpha: Double = isCentre
                                ? baseAlpha * 0.9
                                : (on ? baseAlpha * 0.9 : 0)
                            Circle()
                                .fill(accent.opacity(baseAlpha))
                                .frame(width: dotSize, height: dotSize)
                                .shadow(color: accent.opacity(glowAlpha),
                                        radius: max(0, glowAlpha * 3))
                        }
                    }
                    .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .onAppear { startScanner() }
    }

    /// Loop `phase` 0→1 over ~1.6 s. Honors Reduce Motion: leaves
    /// `phase` pinned so the centre row reads as a steady mid-bright
    /// stripe instead of a travelling scanner.
    private func startScanner() {
        guard !prefs.reduceMotion else {
            phase = 0.5   // pleasant mid-position when motion is off
            return
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }

    /// Left-pad `levels` with zeros so the dot grid keeps a stable width
    /// even before the recorder has emitted `columnCount` samples.
    /// Padding on the left means new audio lights up on the right edge,
    /// matching how the user reads the timeline (latest = newest).
    private static func padLevels(_ levels: [Float], target: Int) -> [Float] {
        guard levels.count < target else { return levels }
        return Array(repeating: 0, count: target - levels.count) + levels
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
                    KeyCap(label: "\u{2303}")
                    KeyCap(label: "\u{2325}")
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
