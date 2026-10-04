import EQCore
import SwiftUI

/// First launch. A menu bar app otherwise opens silently, so this says where
/// Halen lives, asks how calls should start, and gets the microphone
/// permission out of the way before anyone's on a call.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var mode: AppModel.AppMode = .ask
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(spacing: 6) {
                Text("Hear how you come across on calls").font(.title2.bold())
                Text("Halen listens to your side of a call, turns it into a few numbers, and forgets the audio. Everything stays on this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Image(nsImage: MenubarIcon.image(listening: false))
                    .padding(6).background(.quaternary, in: .rect(cornerRadius: 6))
                Text("Halen lives in your menu bar, top right. Click it any time.")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(12)
            .dotCard()

            VStack(alignment: .leading, spacing: 8) {
                DotLabel("When a call starts", size: 11)
                Picker("When a call starts", selection: $mode) {
                    Text("Ask me first").tag(AppModel.AppMode.ask)
                    Text("Listen automatically").tag(AppModel.AppMode.auto)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("You can change this per app in Settings. While Halen listens you'll see a dot by its icon, and macOS's orange microphone dot. That's expected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Open Halen at login", isOn: $openAtLogin).padding(.top, 4)
            }

            HStack {
                Button("Later") { finish(thenVoice: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Set Up Voice Check") { finish(thenVoice: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private func finish(thenVoice: Bool) {
        Task {
            await model.finishOnboarding(mode: mode)
            if openAtLogin != model.launchAtLogin { model.launchAtLogin = openAtLogin }
            dismissWindow(id: "welcome")
            if thenVoice { openWindow(id: "voice"); NSApp.activate() }
        }
    }
}
