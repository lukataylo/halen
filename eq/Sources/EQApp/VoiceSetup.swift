import EQCore
import SwiftUI

/// Voice check setup: read a short passage aloud for 30 s. Builds the voice
/// print (so other voices are ignored) and your calm-voice reference.
struct VoiceSetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    static let passage = """
    When sunlight hits raindrops in the air, they act like a prism and make a rainbow. \
    People say there's a pot of gold at one end. Many look for it, but nobody has found it yet.
    """

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Teach Halen your voice").font(.title2.bold())
                Text("Read this aloud at your normal pace. Halen stops on its own when it has enough, about 15 seconds.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(Self.passage)
                .font(.title3)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .dotCard()

            controls
                .frame(minHeight: 56)

            Label("Your voice print stays on this Mac, encrypted. Delete it any time in Settings.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 480)
        .onDisappear { model.resetEnrollmentState() }
    }

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
                EnrollWave(live: model.live).frame(width: 220)
                HStack(spacing: 12) {
                    ProgressView(value: p).frame(width: 140)
                    Text(p < 1 ? "Keep reading…" : "Got it, pause when you're done").font(.callout).foregroundStyle(.secondary)
                    Button("Done") { model.finishEnrollmentEarly() }
                        .controlSize(.small)
                        .disabled(p < 0.66)
                        .keyboardShortcut(.defaultAction)
                }
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
    var body: some View { HairlineWave(you: live.you, them: nil, cols: 36) }
}
