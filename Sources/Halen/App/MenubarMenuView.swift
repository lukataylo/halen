import SwiftUI

struct MenubarMenuView: View {
    @Bindable var state: AppState

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

        Divider()

        Button("Quit Halen") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLabel: String {
        switch state.permissionStatus {
        case .unknown: return "Permission: checking…"
        case .granted: return "Permission: granted"
        case .denied:  return "Permission: not granted"
        }
    }
}
