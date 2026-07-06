import Foundation
import Observation

/// In-memory list of apps focused this session — feeds the app-tone editor's
/// "recently used apps" picker. Not persisted; a fresh launch rebuilds it
/// as the user moves between apps.
///
/// Owned at app-coordinator scope (not plugin scope) so the tone-profiles
/// editor in Settings can show real apps regardless of whether any
/// plugin happens to be alive at the moment.
@Observable
@MainActor
public final class RecentAppsModel {
    public struct App: Identifiable, Sendable {
        public var id: String { bundleId }
        public let bundleId: String
        public var name: String

        public init(bundleId: String, name: String) {
            self.bundleId = bundleId
            self.name = name
        }
    }

    public private(set) var apps: [App] = []

    public init() {}

    public func note(bundleId: String, name: String) {
        guard !bundleId.isEmpty else { return }
        if let idx = apps.firstIndex(where: { $0.bundleId == bundleId }) {
            apps[idx].name = name
        } else {
            apps.append(App(bundleId: bundleId, name: name))
            apps.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
}
