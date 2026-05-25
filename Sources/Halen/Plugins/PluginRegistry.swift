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
        // Explicit user choice takes precedence over the default-off list —
        // someone who deliberately enabled VoiceDictation and quit should
        // get VoiceDictation on next launch even though it's off by default
        // for new users.
        if let stored = defaults.object(forKey: defaultsKey(for: id)) as? Bool {
            return stored
        }
        // Migration: a returning user who had Typo Fixer or Style Guide
        // on before the merge expects the new Word Replacements plugin to
        // pick up where they left off. Honor either old key as a signal
        // of "user wanted this behaviour", and stamp the migrated value
        // into the new key so the lookup is single-source from then on.
        if id == "com.halen.word-replacements" {
            let migrated = Self.migratedFromLegacy(
                anyOf: ["com.halen.typo-fixer", "com.halen.style-guide"],
                defaults: defaults
            )
            if let migrated {
                defaults.set(migrated, forKey: defaultsKey(for: id))
                return migrated
            }
        }
        return !Self.defaultDisabledPluginIds.contains(id)
    }

    /// Returns `true` if any of `anyOf` was persisted as enabled, `false`
    /// if any was persisted as disabled (with no enabled siblings), or
    /// `nil` if none of them were ever stored (= fresh install, fall
    /// through to defaultDisabled logic).
    private static func migratedFromLegacy(anyOf legacyIds: [String],
                                           defaults: UserDefaults) -> Bool? {
        var anyStored = false
        var anyEnabled = false
        for id in legacyIds {
            let key = "plugin.\(id).enabled"
            guard let value = defaults.object(forKey: key) as? Bool else { continue }
            anyStored = true
            if value { anyEnabled = true }
        }
        guard anyStored else { return nil }
        return anyEnabled
    }

    private func defaultsKey(for id: String) -> String { "plugin.\(id).enabled" }

    /// Plugins that start **off** for a fresh install — the "Pick what's on"
    /// step of onboarding flips them on if the user opts in. Everything not
    /// in this set defaults to on. Picked to match the immediate-value
    /// threshold: a brand-new user should get tone/clarity/typo/ask/snippets
    /// without surprises; the rest are niche (Voice) or interrupt-heavy
    /// (Autocomplete). StyleGuide and EmailReply behaviour now lives inside
    /// the merged Writing Coach + Snippet Expander, so they don't appear
    /// here as their own plugin entries.
    static let defaultDisabledPluginIds: Set<String> = [
        "com.halen.voice-dictation",
        "com.halen.autocomplete",
        "com.halen.style-guide",
        "com.halen.email-reply",
    ]
}
