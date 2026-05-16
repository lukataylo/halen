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

    init(services: HalenServices) {
        self.services = services
        self.bridge = HostBridge(services: services)
    }

    /// Canonical install root. Each subdirectory is one self-contained plugin
    /// (manifest + executable + plugin-local data files). Visible to the user
    /// via Finder so they can install / inspect plugins by hand.
    static var installRoot: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appending(path: "Halen", directoryHint: .isDirectory)
            .appending(path: "Plugins", directoryHint: .isDirectory)
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
        let instance = PluginInstance(manifest: manifest, pluginDir: dir,
                                      handler: { [bridge] method, params in
            // Every plugin-to-host RPC goes through the single `HostBridge`
            // shared with the WebSocket transport, so the surface is
            // identical and can't drift.
            return try await bridge.dispatch(method: method, params: params)
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
