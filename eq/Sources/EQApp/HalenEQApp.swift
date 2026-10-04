import EQCore
import SwiftUI

@main
struct HalenEQApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    init() { Dot.registerFont() }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(model).environmentObject(updater)
        } label: {
            Image(nsImage: MenubarIcon.image(listening: model.isListening))
        }
        .menuBarExtraStyle(.window)

        Window("Halen EQ", id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 900, height: 640)
        .windowToolbarStyle(.unifiedCompact)
        .defaultLaunchBehavior(AppModel.isDemo ? .presented : .suppressed)

        #if DEBUG
        // Demo only: the menu bar popover in a regular window, for screenshots.
        Window("Menu (demo)", id: "menu-demo") {
            MenuBarView().environmentObject(model).environmentObject(updater)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(AppModel.isDemo ? .presented : .suppressed)
        #endif

        Window("Welcome to Halen", id: "welcome") {
            WelcomeView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(AppModel.needsOnboarding ? .presented : .suppressed)

        Window("Voice Check", id: "voice") {
            VoiceSetupView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(AppModel.isDemo ? .presented : .suppressed)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView().environmentObject(model).environmentObject(updater)
        }
    }
}
