import Foundation

/// Dependency container passed to every plugin at construction time. Anything a
/// plugin needs from the host goes through this — the AX caret observer, the
/// shared inference runtime, the event bus, and a scoped support directory for
/// per-plugin persistence.
///
/// In M4 this becomes a JSON-RPC client wrapper. Keep it narrow: the smaller the
/// surface here, the easier the extraction.
@MainActor
struct HalenServices {
    let eventBus: EventBus
    let inference: InferenceClient
    let caretObserver: CaretObserver
    /// Host-owned calendar capability. Exposed to out-of-process plugins via
    /// the `calendar/*` JSON-RPC methods (gated on the `calendar` permission).
    let calendar: CalendarService
    /// Per-app tone profiles. Read by Writing Coach (tone classifier +
    /// clarity rules) and Snippet Expander's email-reply action to bias
    /// their prompts by the focused app's formality. The editor UI lives
    /// in the Writing Assistant's Tone tab; the store is owned by
    /// AppCoordinator.
    let toneProfiles: AppToneProfileStore
    /// Apps the user has recently focused, for the Tone tab's per-app target
    /// picker (so the user picks from a list instead of typing bundle ids).
    /// Owned by AppCoordinator, fed from `app.focused` events.
    let recentApps: RecentAppsModel
    let appSupportDir: URL

    /// `~/Library/Application Support/Halen/<pluginId>/` — make this lazily; not
    /// every plugin needs it.
    func storageDirectory(for pluginId: String) -> URL {
        let dir = appSupportDir.appending(path: pluginId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Single resolver for `~/Library/Application Support/Halen/`. See
    /// `HalenSupportDirectory` — it falls back to a deterministic temp path
    /// instead of force-unwrapping (which would crash the entire app if the
    /// OS ever returned an empty Application Support list).
    static func defaultAppSupportDir() -> URL {
        HalenSupportDirectory.root
    }
}
