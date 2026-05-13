import SwiftUI

@main
struct HalenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            HalenCenterView(
                state: appDelegate.coordinator.state,
                registry: appDelegate.coordinator.registry
            )
        } label: {
            Image(systemName: "text.cursor")
        }
        .menuBarExtraStyle(.window)
    }
}
