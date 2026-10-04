import EQCore
import SwiftUI

/// Voice check setup: read a short passage aloud for 30 s. Builds the voice
/// print (so other voices are ignored) and your calm-voice reference.
struct VoiceSetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    static let passage = """
    When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. \
    The rainbow is a division of white light into many beautiful colours. These take the shape \
    of a long round arch, with its path high above, and its two ends apparently beyond the horizon. \
    There is, according to legend, a boiling pot of gold at one end. People look, but no one ever finds it. \
    When a man looks for something beyond his reach, his friends say he is looking for the pot of gold \
    at the end of the rainbow.
    """

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 34))
            VStack(spacing: 6) {
                Text("Teach Halen EQ your voice").font(.title2.bold())
                Text("Read the passage below at your normal pace for 30 seconds. Halen EQ learns what you sound like, so it ignores everyone else — and what calm sounds like for you.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(Self.passage)
                .font(.title3)
                .lineSpacing(4)
                .padding(16)
                .dotCard()
                .opacity(isRecording ? 1 : 0.85)

            controls
                .frame(height: 64)

            Label("Your voice print stays on this Mac, encrypted. Delete it any time in Settings.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 520)
        .onDisappear { model.resetEnrollmentState() }
    }

    private var isRecording: Bool { if case .recording = model.enrollment { true } else { false } }

    @ViewBuilder private var controls: some View {
        switch model.enrollment {
        case .idle, .failed:
            VStack(spacing: 8) {
                Button {
                    Task { await model.enroll() }
                } label: {
                    Label(model.voicePrint == nil ? "Start Reading" : "Record Again", systemImage: "mic.fill")
                        .frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                if case .failed(let msg) = model.enrollment {
                    Text(msg).font(.callout).foregroundStyle(.orange)
                }
            }
        case .recording(let p):
            VStack(spacing: 10) {
                EnrollWave(live: model.live).frame(width: 300)
                Text("\(Int(((1 - p) * 30).rounded(.up)))").font(Dot.font(26)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true)).animation(.snappy, value: Int((1 - p) * 30))
            }
        case .processing:
            ProgressView("Learning your voice… (first time downloads a small model)").controlSize(.small)
        case .done:
            VStack(spacing: 8) {
                Label("Voice check is on", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Button("Done") { dismissWindow(id: "voice") }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct EnrollWave: View {
    @ObservedObject var live: LiveMeter
    var body: some View { DotWaveform(you: live.you, them: nil, rows: 5) }
}
