import SwiftUI

struct MenubarMenuView: View {
    @Bindable var state: AppState
    let typoStore: TypoStore

    var body: some View {
        Text("Halen")
            .font(.headline)
        Divider()

        Text(statusLabel)
            .foregroundStyle(.secondary)

        Divider()

        Button("Open Accessibility Settings") {
            AXPermissions.openSettings()
        }

        Button("Show learned corrections (\(typoStore.entries.count))") {
            openLearnedCorrectionsFile()
        }

        Button("Reset learned corrections") {
            typoStore.reset()
        }

        Divider()

        Button("Quit Halen") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openLearnedCorrectionsFile() {
        let url = TypoStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? "{\"version\":1,\"entries\":{}}".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private var statusLabel: String {
        switch state.permissionStatus {
        case .unknown: return "Permission: checking…"
        case .granted: return "Permission: granted"
        case .denied:  return "Permission: not granted"
        }
    }
}
