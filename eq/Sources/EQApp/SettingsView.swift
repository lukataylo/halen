import EQCore
import SwiftUI

/// Standard macOS Settings window: General / Voice / Privacy tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Voice", systemImage: "person.wave.2") { VoiceSettings() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings() }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Notice when a call starts", isOn: $model.autoStart)
                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    LabeledContent("Version") {
                        HStack {
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–").foregroundStyle(.secondary)
                            Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                        }
                    }
                }
            }
            Section {
                ForEach(model.installedCallApps, id: \.self) { id in
                    AppModeRow(bundleID: id)
                }
                if model.installedCallApps.isEmpty {
                    Text("No supported call apps found.").foregroundStyle(.secondary)
                }
            } header: {
                Text("When an app uses the mic")
            } footer: {
                Text("Browsers ask first — the mic there isn't always a call. You can always press Start in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.autoStart)
        }
        .formStyle(.grouped)
    }
}

private struct VoiceSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Voice check") {
                    if let p = model.voicePrint {
                        Label("On since \(p.created.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Not set up").foregroundStyle(.secondary)
                    }
                }
                Text("Ignores voices that aren't yours — people in the room, or a call playing through your speakers. Also sets what calm sounds like for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(model.voicePrint == nil ? "Set Up Voice Check…" : "Record Again…") { openWindow(id: "voice"); NSApp.activate() }
                if model.voicePrint != nil {
                    Button("Delete Voice Print…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete your voice print?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteVoicePrint() }
        } message: { Text("Other voices near your mic will no longer be filtered out, and saved transcripts will be turned off.") }
    }
}

private struct PrivacySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Audio") { Text("Never saved").foregroundStyle(.secondary) }
                Toggle("Save my words", isOn: $model.saveTranscripts)
                    .disabled(model.voicePrint == nil)
                Picker("Keep them for", selection: $model.transcriptDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }
                .disabled(!model.saveTranscripts)
            } footer: {
                Text(model.voicePrint == nil
                     ? "Requires voice check, so only your words — never anyone else's — can be saved."
                     : "Only your side, encrypted on this Mac. After this, only the numbers remain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Forget Everything…", role: .destructive) { confirmForget = true }
            } footer: {
                Text("Deletes every conversation, your voice print, and the encryption key.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget everything?", isPresented: $confirmForget) {
            Button("Forget Everything", role: .destructive) { model.forgetEverything() }
        } message: { Text("This can't be undone.") }
    }
}

private struct AppModeRow: View {
    let bundleID: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker(selection: Binding(get: { model.mode(for: bundleID) }, set: { model.setMode($0, for: bundleID) })) {
            ForEach(AppModel.AppMode.allCases) { Text($0.title).tag($0) }
        } label: {
            HStack(spacing: 8) {
                SourceIcon(bundleID: bundleID, size: 20)
                Text(name)
            }
        }
    }

    private var name: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}
