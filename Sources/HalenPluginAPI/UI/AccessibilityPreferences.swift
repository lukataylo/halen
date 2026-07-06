import AppKit
import Observation

/// Live mirror of the two macOS accessibility prefs that Halen's UI cares
/// about: **Reduce Motion** and **Reduce Transparency**. Both live under
/// System Settings → Accessibility → Display.
///
/// Why a singleton? Every overlay, dropdown card, and onboarding panel needs
/// the same values, and they only change when the user flips the toggle in
/// System Settings — there is no per-instance state to track. A shared
/// observable lets any SwiftUI view read `AccessibilityPreferences.shared`
/// and re-render when the user toggles the pref live (no app restart).
///
/// The class subscribes to
/// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, which
/// AppKit posts on `NSWorkspace.shared.notificationCenter` whenever any of
/// the Display accessibility options change. On each notification we re-read
/// the canonical values from `NSWorkspace.shared`; the @Observable storage
/// then drives a SwiftUI redraw.
///
/// `@MainActor` because reading `NSWorkspace.shared.*` must happen on the
/// main thread, and the observer also fires there.
@MainActor
@Observable
final class AccessibilityPreferences {
    /// Shared instance. Use this from SwiftUI views — there's no reason to
    /// construct your own; the values are global to the running app anyway.
    static let shared = AccessibilityPreferences()

    /// True when macOS's "Reduce motion" pref is on. UI animations
    /// (spinners, slide transitions, breathing glows) should be replaced
    /// with static equivalents — vestibular-disorder users get motion
    /// sickness from large rotating or sliding elements.
    private(set) var reduceMotion: Bool

    /// True when macOS's "Reduce transparency" pref is on. Translucent
    /// `.regularMaterial` / `.thinMaterial` / `.ultraThinMaterial`
    /// backgrounds should fall back to an opaque colour — low-vision users
    /// need solid surfaces for legible contrast.
    private(set) var reduceTransparency: Bool

    /// Held strong so we can `removeObserver` on deinit. AppKit's
    /// addObserver(forName:…) returns an opaque token that's the only way
    /// to unregister a block-based observer.
    ///
    /// `@ObservationIgnored` keeps the `@Observable` macro from wrapping
    /// this in tracking storage — the token is internal lifecycle
    /// bookkeeping that SwiftUI doesn't need to observe, and the macro's
    /// generated wrapper can't accept `nonisolated`.
    ///
    /// `nonisolated(unsafe)` because `deinit` runs on whatever thread
    /// releases the last reference — not necessarily MainActor — and
    /// needs to read this to unregister. Written exactly once (in `init`,
    /// before any reference can escape) and read once (in `deinit`,
    /// after every other reference has dropped), so there's no concurrent
    /// access. The singleton in practice never deallocates while the app
    /// is running.
    @ObservationIgnored
    nonisolated(unsafe) private var observerToken: NSObjectProtocol?

    private init() {
        let ws = NSWorkspace.shared
        self.reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        self.reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency

        // `NSWorkspace.shared.notificationCenter` — NOT the default
        // NotificationCenter. AppKit posts accessibility-display change
        // notifications on the workspace's private centre.
        self.observerToken = ws.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer is queued on .main, but the closure isn't
            // statically @MainActor — bounce through a Task to satisfy
            // the actor checker without dropping the update. Re-capture
            // `self` weakly on the Task closure so Swift 5.10's strict
            // concurrency checker doesn't flag "reference to captured
            // var 'self' in concurrently-executing code" (the outer
            // observer closure is non-Sendable; the inner Task closure
            // is, so the capture has to be made explicit again).
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        // `observerToken` is @MainActor-isolated; deinit runs on whichever
        // thread last released the instance. The token is an opaque
        // NSObjectProtocol — safe to remove from any thread, the workspace
        // notification centre is thread-safe for unregister. We bypass the
        // actor by reading the stored property via an unsafe pointer.
        // In practice `AccessibilityPreferences.shared` is a singleton and
        // never deallocates while the app is running, so this code path is
        // defensive only.
        if let token = self.observerToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// Re-read both values from NSWorkspace. Called from the observer; also
    /// safe to call manually (no-op if nothing changed — @Observable only
    /// notifies on actual property writes).
    private func refresh() {
        let ws = NSWorkspace.shared
        let newMotion = ws.accessibilityDisplayShouldReduceMotion
        let newTransparency = ws.accessibilityDisplayShouldReduceTransparency
        if newMotion != reduceMotion {
            reduceMotion = newMotion
            Log.info("Accessibility: reduceMotion=\(newMotion)")
        }
        if newTransparency != reduceTransparency {
            reduceTransparency = newTransparency
            Log.info("Accessibility: reduceTransparency=\(newTransparency)")
        }
    }
}

// MARK: - AdaptiveMaterial

import SwiftUI

/// ViewModifier that swaps a translucent SwiftUI `Material` for an opaque
/// fallback colour when macOS's "Reduce transparency" pref is on.
///
/// Apply on the same surface where you'd write `.background(.thinMaterial)`:
///
/// ```swift
/// .adaptiveMaterial(.thinMaterial)
/// ```
///
/// Honors `AccessibilityPreferences.shared.reduceTransparency` live — flip
/// the pref in System Settings and the view restyles without restart.
@MainActor
struct AdaptiveMaterial: ViewModifier {
    let material: Material
    let fallback: Color

    @State private var prefs = AccessibilityPreferences.shared

    func body(content: Content) -> some View {
        if prefs.reduceTransparency {
            // Opaque surface — windowBackgroundColor adapts to light/dark
            // mode automatically, so we don't need a separate dark variant.
            content.background(fallback)
        } else {
            content.background(material)
        }
    }
}

extension View {
    /// Honors macOS's "Reduce transparency" accessibility pref. Use in place
    /// of a raw `.background(<Material>)` on glassy surfaces so low-vision
    /// users get an opaque, high-contrast fallback.
    func adaptiveMaterial(
        _ material: Material,
        fallback: Color = Color(nsColor: .windowBackgroundColor)
    ) -> some View {
        modifier(AdaptiveMaterial(material: material, fallback: fallback))
    }
}
