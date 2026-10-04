import Foundation
import AppKit
import ApplicationServices

/// Top-level orchestrator for out-of-process plugins. Discovers manifests
/// under `~/Library/Application Support/Halen/Plugins/`, spawns each as a
/// `PluginInstance`, routes EventBus events to those that subscribed in
/// their manifest, and handles incoming plugin-to-host RPC calls (inference,
/// AX, UI) by delegating to the existing in-process services.
///
/// Crash isolation comes free from the one-subprocess-per-plugin model —
/// a plugin that segfaults takes nothing else down. A future iteration can
/// add automatic restart with exponential backoff; today a crashed plugin
/// stays dead until next launch.
@MainActor
final class PluginHost {
    private let services: HalenServices
    private let bridge: HostBridge
    private var instances: [PluginInstance] = []
    private var subscriptionTask: Task<Void, Never>?

    /// Per-plugin hotkey registrations. Outer key is the plugin's manifest
    /// id; inner key is the plugin-chosen id string (e.g. "rephrase-on-r")
    /// that the plugin will see in subsequent `hotkey.fired` events. Each
    /// inner value holds the Carbon registrar so we can unregister cleanly
    /// on terminate.
    private var hotkeys: [String: [String: HotkeyRegistrar]] = [:]
    /// Carbon's `EventHotKeyID` integer space is shared process-wide.
    /// In-process hotkeys use ids 1–4 (`HotkeyID` enum); plugin-allocated
    /// ones start at 1 000 so they can never collide.
    private var nextCarbonId: UInt32 = 1_000

    init(services: HalenServices) {
        self.services = services
        self.bridge = HostBridge(services: services)
    }

    /// Canonical install root. Each subdirectory is one self-contained plugin
    /// (manifest + executable + plugin-local data files). Visible to the user
    /// via Finder so they can install / inspect plugins by hand.
    static var installRoot: URL {
        HalenSupportDirectory.subdirectory("Plugins")
    }

    /// Discover the manifests under `installRoot` without spawning anything.
    /// Auto-creates the install dir if missing so the user has somewhere
    /// to drop a plugin without first running `mkdir -p`. Returns the list
    /// so `AppCoordinator` can wrap each in an `ExternalPluginAdapter` and
    /// register it with the marketplace.
    func discoverManifests() -> [(URL, PluginManifest)] {
        let root = Self.installRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let discovered = PluginManifest.discoverAll(under: root)
        if !discovered.isEmpty {
            Log.info("PluginHost: discovered \(discovered.count) external plugin(s)")
        } else {
            Log.info("PluginHost: no external plugins found under \(root.path)")
        }
        return discovered
    }

    /// Spawn the plugin process for `manifest`. Idempotent — calling with a
    /// manifest whose id is already running is a no-op. Called by
    /// `ExternalPluginAdapter.start()` (which is in turn called by the
    /// `PluginRegistry` when the plugin is enabled at launch or by the user).
    func spawn(at dir: URL, manifest: PluginManifest) async {
        guard !instances.contains(where: { $0.manifest.id == manifest.id }) else { return }
        // The plugin's granted permission set — what it declared in its
        // manifest. `HostBridge` gates sensitive methods (calendar/*) on it.
        let granted = Set(manifest.permissions ?? [])
        let pluginId = manifest.id   // captured by the per-instance handler
        // Captured separately because the conflict registry surfaces a
        // human label (manifest name), not the dotted reverse-DNS id.
        let pluginName = manifest.name
        let instance = PluginInstance(manifest: manifest, pluginDir: dir,
                                      handler: { [bridge, weak self] method, params in
            // Per-plugin methods (hotkey/*) need plugin identity to route
            // fired events back; intercept them here before falling
            // through to the shared bridge. Every other RPC goes through
            // the single `HostBridge` shared with the WebSocket transport,
            // so the surface is identical and can't drift.
            switch method {
            case "hotkey/register", "hotkey/unregister":
                guard let self else {
                    throw RPCErrorObject(code: PluginRPC.ErrorCode.internalError.rawValue,
                                         message: "Plugin host shutting down", data: nil)
                }
                return try await self.handleHotkey(method: method, params: params,
                                                   pluginId: pluginId,
                                                   pluginName: pluginName)
            default:
                return try await bridge.dispatch(method: method, params: params,
                                                 grantedPermissions: granted)
            }
        })
        do {
            try await instance.start()
            instances.append(instance)
        } catch {
            Log.warn("PluginHost: \(manifest.id) failed to start — \(error.localizedDescription)")
        }
    }

    /// Polite termination of a single plugin. Called by
    /// `ExternalPluginAdapter.stop()` when the user toggles the plugin off.
    func terminate(id: String) async {
        guard let instance = instances.first(where: { $0.manifest.id == id }) else { return }
        await instance.terminate()
        instances.removeAll { $0.manifest.id == id }
        // Unregister any Carbon hotkeys this plugin held. Without this,
        // toggling Voice Dictation off would leave its ⌃⌥Space hotkey live
        // (Carbon's registration outlives the plugin process otherwise).
        if let registered = hotkeys.removeValue(forKey: id) {
            for (_, registrar) in registered {
                registrar.unregister()
            }
        }
    }

    // MARK: - Hotkey RPC

    /// Implements `hotkey/register` and `hotkey/unregister` for a specific
    /// plugin. Registration installs a Carbon hotkey whose on-fire closure
    /// pushes `hotkey.fired` back to the plugin via `PluginInstance.deliver`;
    /// the plugin must list `hotkey.fired` in its manifest's `events` to
    /// actually receive the notification (the existing manifest allow-list
    /// path).
    ///
    /// `params` shape:
    ///   - `id`:        plugin-chosen identifier string (e.g. "rephrase").
    ///                  Echoed back in the fired event so the plugin can
    ///                  distinguish between multiple registered hotkeys.
    ///   - `keyCode`:   Carbon virtual key code (e.g. `kVK_ANSI_E` = 14).
    ///   - `modifiers`: bitmask of Carbon modifier flags (`controlKey`,
    ///                  `optionKey`, `cmdKey`, `shiftKey`).
    private func handleHotkey(method: String, params: RPCValue?,
                              pluginId: String,
                              pluginName: String) async throws -> RPCValue {
        let obj = params?.objectValue
        guard let hotkeyId = obj?["id"]?.stringValue else {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.invalidParams.rawValue,
                                 message: "\(method) requires `id`", data: nil)
        }

        switch method {
        case "hotkey/register":
            guard let keyCode = obj?["keyCode"]?.intValue,
                  let modifiers = obj?["modifiers"]?.intValue else {
                throw RPCErrorObject(code: PluginRPC.ErrorCode.invalidParams.rawValue,
                                     message: "hotkey/register requires `keyCode` and `modifiers`",
                                     data: nil)
            }
            // Re-registering the same plugin/id pair replaces the existing
            // hotkey rather than stacking two on the same key combo.
            if let prior = hotkeys[pluginId]?[hotkeyId] {
                prior.unregister()
                hotkeys[pluginId]?.removeValue(forKey: hotkeyId)
            }
            let carbonId = nextCarbonId
            nextCarbonId &+= 1
            let registrar = HotkeyRegistrar()
            let ok = registrar.register(
                keyCode: UInt32(keyCode),
                modifiers: UInt32(modifiers),
                id: carbonId,
                owner: pluginName
            ) { [weak self] in
                // Re-capture self on the Task closure — Swift 5.10's
                // strict concurrency rejects the outer-closure capture
                // being read inside a concurrently-executing Task body.
                Task { @MainActor [weak self] in
                    self?.deliverHotkeyFired(pluginId: pluginId, hotkeyId: hotkeyId)
                }
            }
            guard ok else {
                // Could be a Halen-internal conflict (another plugin holds
                // the chord — surfaced in Settings) or a Carbon-level
                // refusal (another app owns it). The plugin sees the same
                // RPC error either way; the user-facing distinction is in
                // the Settings warning card.
                throw RPCErrorObject(code: PluginRPC.ErrorCode.internalError.rawValue,
                                     message: "Hotkey refused — see Settings → Conflicting hotkeys, or another app may own this chord",
                                     data: nil)
            }
            hotkeys[pluginId, default: [:]][hotkeyId] = registrar
            Log.info("PluginHost: \(pluginId) registered hotkey \(hotkeyId) keyCode=\(keyCode) mods=\(modifiers)")
            return .object(["ok": true] as [String: Any?])

        case "hotkey/unregister":
            if let registrar = hotkeys[pluginId]?[hotkeyId] {
                registrar.unregister()
                hotkeys[pluginId]?.removeValue(forKey: hotkeyId)
                Log.info("PluginHost: \(pluginId) unregistered hotkey \(hotkeyId)")
            }
            return .object(["ok": true] as [String: Any?])

        default:
            // Unreachable — outer switch only routes these two strings here.
            throw RPCErrorObject(code: PluginRPC.ErrorCode.methodNotFound.rawValue,
                                 message: "Unknown hotkey method: \(method)", data: nil)
        }
    }

    /// Push a `hotkey.fired` notification to the plugin. The Carbon callback
    /// runs on the main run loop already (CarbonHIToolbox dispatches on the
    /// main thread), but we double-down by routing through `@MainActor` so
    /// the `instances` lookup is unambiguously isolated.
    private func deliverHotkeyFired(pluginId: String, hotkeyId: String) {
        guard let instance = instances.first(where: { $0.manifest.id == pluginId }) else { return }
        instance.deliver(event: "hotkey.fired", payload: .object([
            "id": hotkeyId,
            "timestamp": Date().timeIntervalSince1970
        ] as [String: Any?]))
    }

    /// Start the event-bus → plugin fan-out. Idempotent. AppCoordinator calls
    /// this once after registering every external plugin.
    func startEventDispatcher() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.services.eventBus.subscribe() {
                self.dispatch(event)
            }
        }
    }

    /// Polite shutdown of every plugin. Called from `AppCoordinator.shutdown()`.
    func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        for instance in instances {
            await instance.terminate()
        }
        instances.removeAll()
    }

    // MARK: - Event dispatch

    /// Map each `Event` to the protocol's `(topic, payload)` shape via the
    /// shared `Event.toBroadcast()` helper, then fan out to instances whose
    /// manifest declared interest in that topic.
    private func dispatch(_ event: Event) {
        guard let (topic, payload) = event.toBroadcast() else { return }
        for instance in instances {
            instance.deliver(event: topic, payload: payload)
        }
    }
}
