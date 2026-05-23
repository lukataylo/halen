import SwiftUI
import AppKit

@main
struct HalenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            HalenCenterView(
                state: appDelegate.coordinator.state,
                registry: appDelegate.coordinator.registry,
                inferenceSettings: appDelegate.coordinator.inferenceSettings,
                router: appDelegate.coordinator.inference,
                modelDownloader: appDelegate.coordinator.modelDownloader,
                webSocketBridge: appDelegate.coordinator.webSocketBridge,
                launchAtLogin: appDelegate.coordinator.launchAtLogin,
                hotkeyConflicts: appDelegate.coordinator.hotkeyConflicts,
                onOpenStore: { appDelegate.coordinator.pluginStoreWindow.show() },
                onRunSetupAgain: { appDelegate.coordinator.onboardingWindow.presentAgain() },
                updater: appDelegate.coordinator.updater,
                quickActions: QuickActionsBridge(
                    isAvailable: { appDelegate.coordinator.isPluginEnabled($0) },
                    askHalen:           { appDelegate.coordinator.invokeAskHalen() },
                    rephraseSelection:  { appDelegate.coordinator.invokeRephraseSelection() },
                    emailReply:         { appDelegate.coordinator.invokeEmailReply() },
                    startDictation:     { appDelegate.coordinator.invokeStartDictation() }
                )
            )
        } label: {
            Image(nsImage: Self.menubarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Loaded once at startup. Set as a template image so macOS tints it
    /// black or white to match the menubar's appearance. Falls back to the
    /// SF Symbol if the asset isn't bundled (e.g., dev runs before icons exist).
    private static let menubarIcon: NSImage = {
        let image = NSImage(named: "HalenMenubar")
            ?? NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Halen")
            ?? NSImage()
        image.isTemplate = true
        // Cap at macOS menubar standard so it sits the same height as adjacent items.
        image.size = NSSize(width: 16, height: 16)
        return image
    }()
}
