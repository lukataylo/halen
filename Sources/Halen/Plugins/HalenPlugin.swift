import Foundation

/// Every Halen feature ships as a `HalenPlugin`. In M4 these will be hoisted into
/// out-of-process processes talking JSON-RPC; for now they live in-host as Swift
/// modules so the rough edges of the contract surface in real use before we lock it.
///
/// Lifecycle:
///   - `start()` is called when the plugin is enabled by the user (or at startup
///     if it was enabled previously). Subscribe to `services.eventBus`, register
///     hotkeys, etc. here.
///   - `stop()` must clean up everything: cancel tasks, close windows, unregister
///     observers. The plugin can be enabled again later via `start()`.
@MainActor
protocol HalenPlugin: AnyObject {
    /// Stable reverse-DNS identifier used for UserDefaults persistence and the eventual
    /// out-of-process manifest. Don't change this once shipped.
    var id: String { get }

    /// Human-readable name shown in the marketplace.
    var name: String { get }

    /// One-line description shown under the name (~70 chars max for layout).
    var summary: String { get }

    /// SF Symbol name used as the row icon.
    var icon: String { get }

    /// Category bucket the plugin shows up under.
    var category: PluginCategory { get }

    func start()
    func stop()
}

enum PluginCategory: String, CaseIterable, Sendable {
    case writing
    case voice
    case scheduling
    case focus
    case productivity

    var label: String {
        switch self {
        case .writing: return "Writing"
        case .voice: return "Voice"
        case .scheduling: return "Scheduling"
        case .focus: return "Focus"
        case .productivity: return "Productivity"
        }
    }
}
