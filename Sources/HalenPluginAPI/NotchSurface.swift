import AppKit
import SwiftUI

/// Identity + geometry of one screen the notch surface renders on.
public struct NotchScreenInfo: Hashable, Sendable {
    public let screenID: CGDirectDisplayID
    /// True when the screen has a physical notch (safe-area inset at top).
    public let hasNotch: Bool
    public let frame: CGRect

    public init(screenID: CGDirectDisplayID, hasNotch: Bool, frame: CGRect) {
        self.screenID = screenID
        self.hasNotch = hasNotch
        self.frame = frame
    }
}

/// The notch surface: one always-on-top, transparent, click-through-when-idle
/// panel per screen, top-center, above the menu bar. The host owns window
/// lifecycle (creation, screen-parameter changes, level, collection
/// behavior); the plugin owns everything drawn inside.
///
/// Exactly one plugin can hold the surface at a time — it's a physical strip
/// of pixels, not a multiplexed feed.
@MainActor
public protocol NotchSurfaceService: AnyObject {
    /// Claim the surface. Throws `NotchSurfaceError.alreadyHeld` if another
    /// plugin got there first. `content` is invoked once per screen (and
    /// again whenever screens change) to produce that screen's root view.
    func acquire(panelSize: CGSize,
                 content: @escaping @MainActor (NotchScreenInfo) -> AnyView) throws -> NotchSurfaceHandle
}

@MainActor
public protocol NotchSurfaceHandle: AnyObject {
    /// Fires on any left-click outside the panels — the conventional
    /// "collapse the expanded surface" signal.
    var onOutsideClick: (@MainActor () -> Void)? { get set }
    /// Rebuild the per-screen content views (e.g. after a settings change
    /// that alters layout). Screen changes trigger this automatically.
    func reloadContent()
    /// Release the surface and close every panel. Call from `stop()`.
    func release()
}

public enum NotchSurfaceError: Error, LocalizedError {
    case alreadyHeld(byPluginId: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyHeld(let id):
            return "The notch surface is already held by \(id)"
        }
    }
}
