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
        // Migration: merged plugins inherit their enabled-state from
        // whichever of the legacy ids was last persisted. Honor any
        // legacy "on" as user intent ("I wanted this behaviour"); stamp
        // the migrated value into the new key so subsequent lookups are
        // single-source.
        // Merge migrations where the legacy plugins were default-ON
        // (typo-fixer, style-guide, sentiment-guard, clarity-checker).
        // A returning user's explicit on or off carries straight
        // through: any legacy "on" → new id on; all legacies stored as
        // "off" → new id off (the user opted out of that behaviour and
        // we should preserve that across the merge).
        let strictMigrations: [String: [String]] = [
            "com.halen.word-replacements": ["com.halen.typo-fixer",
                                            "com.halen.style-guide"],
            "com.halen.writing-coach":     ["com.halen.sentiment-guard",
                                            "com.halen.clarity-checker"],
        ]
        if let legacy = strictMigrations[id],
           let migrated = Self.migratedFromLegacy(anyOf: legacy, defaults: defaults) {
            defaults.set(migrated, forKey: defaultsKey(for: id))
            return migrated
        }

        // Additive migrations where the legacy plugin was default-OFF
        // (email-reply folded into snippet-expander). A "false" legacy
        // value is ambiguous between "user explicitly opted out" and
        // "user never touched the default-off toggle", so we only
        // honor the migration when the legacy was explicitly enabled.
        // Default-on state of the host plugin (snippet-expander) is
        // preserved otherwise.
        let additiveMigrations: [String: [String]] = [
            "com.halen.snippet-expander": ["com.halen.email-reply"],
        ]
        if let legacy = additiveMigrations[id],
           let migrated = Self.migratedFromLegacy(anyOf: legacy, defaults: defaults),
           migrated {
            defaults.set(true, forKey: defaultsKey(for: id))
            return true
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

    /// Plugins that start **off** for a fresh install — the "Pick what's
    /// on" step of onboarding flips them on if the user opts in.
    /// Everything not in this set defaults to on. Picked to match the
    /// immediate-value threshold: a brand-new user gets Ask Halen, Word
    /// Replacements, Writing Coach, and Snippet Expander (which carries
    /// the folded-in email-reply action). Voice Dictation and Inline
    /// Autocomplete stay opt-in — Voice needs mic/speech permission
    /// prompts the user shouldn't get on first launch, Autocomplete's
    /// ghost-text is continuously interrupting and deserves consent.
    static let defaultDisabledPluginIds: Set<String> = [
        "com.halen.voice-dictation",
        "com.halen.autocomplete",
    ]
}
