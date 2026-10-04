import SwiftUI
#if !APPSTORE
import Sparkle
#endif

/// Sparkle 2 auto-updates. Feed and public key live in Info.plist
/// (SUFeedURL / SUPublicEDKey); every update is EdDSA-verified before it
/// replaces the app. This is one of only two network requests Halen EQ makes
/// (the other is the one-time voice model download).
#if APPSTORE
/// The App Store build updates through the App Store; nothing to show.
@MainActor
final class Updater: ObservableObject {
    @Published var canCheck = false
    var isAvailable: Bool { false }
    func checkForUpdates() {}
    var automaticallyChecks: Bool { get { false } set {} }
}
#else
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published var canCheck = false

    init() {
        // No updater for `swift run` / demo builds — there's no bundle to replace.
        let bundled = Bundle.main.bundleURL.pathExtension == "app" && !AppModel.isDemo
        controller = bundled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        controller?.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
}
#endif
