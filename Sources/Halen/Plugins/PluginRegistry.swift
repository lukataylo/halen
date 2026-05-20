import Foundation
import Observation

/// Owns the set of registered plugins and their enabled/disabled state. State is
/// persisted in `UserDefaults` so toggles survive restarts. The registry is
/// `@Observable` so the marketplace UI updates immediately on toggle.
@Observable
@MainActor
final class PluginRegistry {
    private(set) var plugins: [any HalenPlugin] = []
    private var enabledStates: [String: Bool] = [:]

    private let defaults = UserDefaults.standard

    /// Add a plugin. Honors the previously-saved enabled state (default: enabled).
    func register(_ plugin: any HalenPlugin) {
        guard !plugins.contains(where: { $0.id == plugin.id }) else {
            Log.warn("PluginRegistry: \(plugin.id) already registered — skipping")
            return
        }
        plugins.append(plugin)
        let enabled = readPersistedEnabled(plugin.id)
        enabledStates[plugin.id] = enabled
        if enabled {
            plugin.start()
            Log.info("PluginRegistry: started \(plugin.id)")
        } else {
            Log.info("PluginRegistry: registered \(plugin.id) (disabled)")
        }
    }

    func isEnabled(_ pluginId: String) -> Bool {
        enabledStates[pluginId] ?? readPersistedEnabled(pluginId)
    }

    func toggle(_ pluginId: String) {
        let newValue = !isEnabled(pluginId)
        enabledStates[pluginId] = newValue
        defaults.set(newValue, forKey: defaultsKey(for: pluginId))
        guard let plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        if newValue {
            plugin.start()
            Log.info("PluginRegistry: enabled \(pluginId)")
        } else {
            plugin.stop()
            Log.info("PluginRegistry: disabled \(pluginId)")
        }
    }

    /// Remove a plugin from the registry. Stops it first if it was running.
    /// Used by the Plugin Store's "Remove" action for external plugins — the
    /// caller is responsible for deleting the on-disk plugin directory after
    /// this returns. The persisted enabled/disabled flag is left in
    /// `UserDefaults` intentionally: a reinstall of the same plugin id keeps
    /// the user's previous on/off choice.
    func unregister(_ pluginId: String) {
        guard let plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        if isEnabled(pluginId) {
            plugin.stop()
        }
        plugins.removeAll { $0.id == pluginId }
        enabledStates.removeValue(forKey: pluginId)
        Log.info("PluginRegistry: unregistered \(pluginId)")
    }

    func contains(_ pluginId: String) -> Bool {
        plugins.contains { $0.id == pluginId }
    }

    var activeCount: Int {
        plugins.lazy.filter { self.isEnabled($0.id) }.count
    }

    private func readPersistedEnabled(_ id: String) -> Bool {
        defaults.object(forKey: defaultsKey(for: id)) as? Bool ?? true
    }

    private func defaultsKey(for id: String) -> String { "plugin.\(id).enabled" }
}
