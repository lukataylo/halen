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

    /// Discover and start every plugin under `installRoot`. Failures are
    /// per-plugin: a broken manifest skips just that plugin, the rest still
    /// boot. Idempotent — calling twice without `stop()` is a no-op (the
    /// existing instances stay live).
    func start() async {
        guard instances.isEmpty else { return }
        let root = Self.installRoot
        // Auto-create the directory the first time so the user has somewhere
        // to drop a plugin without first running `mkdir -p`.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let discovered = PluginManifest.discoverAll(under: root)
        guard !discovered.isEmpty else {
            Log.info("PluginHost: no external plugins found under \(root.path)")
            return
        }
        Log.info("PluginHost: discovered \(discovered.count) external plugin(s)")

        for (dir, manifest) in discovered {
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

        startEventDispatcher()
    }

    /// Polite shutdown of every plugin. Called from `AppCoordinator.stop()`.
    func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        for instance in instances {
            await instance.terminate()
        }
        instances.removeAll()
    }

    // MARK: - Event dispatch

    private func startEventDispatcher() {
        subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.services.eventBus.subscribe() {
                self.dispatch(event)
            }
        }
    }

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
