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
    /// Per-app tone profiles. A shared read for the writing plugins (Sentiment
    /// Guard, Clarity Checker); the Tone Profiles plugin owns the editor.
    let toneProfiles: AppToneProfileStore
    let appSupportDir: URL

    /// `~/Library/Application Support/Halen/<pluginId>/` — make this lazily; not
    /// every plugin needs it.
    func storageDirectory(for pluginId: String) -> URL {
        let dir = appSupportDir.appending(path: pluginId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func defaultAppSupportDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appending(path: "Halen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
