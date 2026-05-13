import SwiftUI

@main
struct HalenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenubarMenuView(state: appDelegate.coordinator.state)
        } label: {
            Image(systemName: "text.cursor")
        }
        .menuBarExtraStyle(.menu)
    }
}
