import Foundation
import AppKit
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest of
/// the codebase doesn't import Sparkle directly, and so the controller can be
/// silently skipped in environments where SUFeedURL / SUPublicEDKey aren't
/// set (debug builds without a configured appcast, CI smoke tests, the
/// `HALEN_SELFTEST` path).
///
/// Sparkle reads its config from Info.plist on init. Halen's Info.plist
/// supplies:
///   - SUFeedURL              — https://halen.dev/appcast.xml
///   - SUPublicEDKey          — EdDSA pubkey for verifying update payloads
///   - SUEnableAutomaticChecks → true
///   - SUScheduledCheckInterval → 86 400 s (daily)
///
/// The updater runs on the menubar app's main run loop; no extra threads or
/// timers needed on our side. Sparkle handles the download/verify/install/
/// relaunch dance via its own helper bundle inside Sparkle.framework.
@MainActor
final class UpdaterController: NSObject {
    /// Lives for the app's lifetime — Sparkle's controller holds the
    /// underlying updater driver, and releasing it tears the check loop
    /// down.
    private let controller: SPUStandardUpdaterController

    /// Whether Sparkle has a valid feed URL + public key. False in debug
    /// builds that don't ship with the EdDSA public key wired into
    /// Info.plist (e.g. fresh clone, no Sparkle keypair generated yet).
    /// Settings hides the "Check for Updates" button when this is false
    /// so users don't tap a button that can't do anything.
    let isActive: Bool

    override init() {
        // `startingUpdater: false` lets us inspect the Info.plist config
        // ourselves before deciding whether to start the check loop. The
        // alternative — startingUpdater: true — would log a Sparkle error
        // on every launch in a misconfigured build, which is noisy and
        // confuses local-dev sessions.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let info = Bundle.main.infoDictionary ?? [:]
        let feed   = info["SUFeedURL"] as? String ?? ""
        let pubKey = info["SUPublicEDKey"] as? String ?? ""
        self.isActive = !feed.isEmpty && !pubKey.isEmpty

        super.init()

        guard isActive else {
            Log.info("Updater: skipping — SUFeedURL or SUPublicEDKey missing from Info.plist")
            return
        }

        do {
            try controller.updater.start()
            Log.info("Updater: started — feed=\(feed) daily=\(controller.updater.automaticallyChecksForUpdates)")
        } catch {
            Log.warn("Updater: Sparkle refused to start — \(error.localizedDescription)")
        }
    }

    /// Surface the same "Check for Updates…" action SwiftUI views can bind
    /// to. Mirrors the menu-bar item Sparkle would expose if we shipped
    /// one — we don't, because Halen has no app menu (it's an accessory
    /// app); Settings is the single entry point.
    func checkForUpdates() {
        guard isActive else {
            Log.warn("Updater: checkForUpdates() called but Sparkle is inactive")
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Bound to a SwiftUI Button's `disabled` modifier — Sparkle says
    /// `canCheckForUpdates` is false while a check is already in flight,
    /// during installation, etc.
    var canCheckForUpdates: Bool {
        isActive && controller.updater.canCheckForUpdates
    }
}
