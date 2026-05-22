import SwiftUI
import Observation

/// Per-app tone profiles. The store itself is a host service
/// (`HalenServices.toneProfiles`) that Sentiment Guard and Clarity Checker
/// read; this plugin is the *editor* — its detail view assigns a register to
/// each app. It also tracks recently-focused apps so the editor can offer
/// real apps instead of asking the user to type bundle ids by hand.
@MainActor
final class ToneProfiles: HalenPlugin {
    let id = "com.halen.tone-profiles"
    let name = "Tone Profiles"
    let summary = "Tell Halen which apps are formal and which are casual."
    let icon = "slider.horizontal.3"
    let category: PluginCategory = .writing

    private let services: HalenServices
    let store: AppToneProfileStore
    /// Recently-focused apps, so the editor can list real apps rather than
    /// asking the user to type bundle ids.
    let recentApps = RecentAppsModel()
    private var task: Task<Void, Never>?

    init(services: HalenServices) {
        self.services = services
        self.store = services.toneProfiles
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
                guard let self else { return }
                if case .appFocused(let payload) = event {
                    self.recentApps.note(bundleId: payload.appBundleId, name: payload.appName)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func makeDetailView() -> AnyView {
        AnyView(ToneProfilesDetailView(store: store, recentApps: recentApps))
    }
}

/// In-memory list of apps focused this session — feeds the editor's
/// "recently used apps" picker. Not persisted; a fresh launch rebuilds it as
/// the user moves between apps.
@Observable
@MainActor
final class RecentAppsModel {
    struct App: Identifiable, Sendable {
        var id: String { bundleId }
        let bundleId: String
        var name: String
    }

    private(set) var apps: [App] = []

    func note(bundleId: String, name: String) {
        guard !bundleId.isEmpty else { return }
        if let idx = apps.firstIndex(where: { $0.bundleId == bundleId }) {
            apps[idx].name = name
        } else {
            apps.append(App(bundleId: bundleId, name: name))
            apps.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
}
