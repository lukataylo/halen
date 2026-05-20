import Foundation
import Observation

@Observable
final class AppState {
    var permissionStatus: PermissionStatus = .unknown
}

enum PermissionStatus {
    case unknown
    case granted
    case denied
}

@MainActor
final class AppCoordinator {
    let state = AppState()
    let eventBus = EventBus()
    let inferenceSettings = InferenceSettings()
    let modelDownloader = ModelDownloader()
    let inference: RouterInferenceClient
    let typoStore = TypoStore()
    let registry = PluginRegistry()
    /// Surfaced to Settings via HalenApp → HalenCenterView. Lives at app
    /// scope (not view scope) so its observable status survives the
    /// menubar popup closing and re-opening.
    let launchAtLogin = LaunchAtLoginController()

    /// Backs the Plugin Store. App-scoped so its fetched registry and
    /// in-progress install state survive the menubar popup closing. A freshly
    /// installed plugin is handed straight back to `registerInstalledPlugin`
    /// so it goes live without an app restart.
    lazy var pluginStoreModel: PluginStoreModel = {
        PluginStoreModel(registry: registry) { [weak self] dir, manifest in
            self?.registerInstalledPlugin(directory: dir, manifest: manifest)
        }
    }()

    /// The Plugin Store's standalone window — opened from the dropdown's
    /// header button, lives independently of the menubar popover.
    lazy var pluginStoreWindow: PluginStoreWindowController = {
        PluginStoreWindowController(registry: registry, model: pluginStoreModel)
    }()

    /// Kept around so we can prewarm Apple FM at launch and re-probe
    /// availability from the Settings UI without going through the router.
    let backends: [InferenceBackend]

    private var caretObserver: CaretObserver?
    private var overlay: OverlayController?
    private var pluginHost: PluginHost?
    /// `private(set)` so the Settings UI can observe `isListening` /
    /// `clientCount` and call `start()`/`stop()` when the user toggles
    /// the bridge on or off.
    private(set) var webSocketBridge: WebSocketBridge?

    private var permissionPollTask: Task<Void, Never>?
    private var eventLogTask: Task<Void, Never>?
    /// Set once `stop()` runs, so a permission-poll tick that already passed its
    /// cancellation check can't still spin up observers after shutdown.
    private var isStopped = false

    init() {
        let backends = InferenceBackends.makeAll()
        self.backends = backends
        self.inference = RouterInferenceClient(backends: backends, settings: inferenceSettings)
    }

    func start() {
        Log.info("Halen starting")
        // Hard ceiling on every AX call's blocking duration. Set process-wide
        // before any AX read happens so a frozen target app can't wedge the
        // main thread — `CaretObserver` re-applies per app element on each
        // focus change as belt-and-suspenders.
        axInstallGlobalMessagingTimeout()
        startEventLogger()
        // Best-effort prewarm of Apple Foundation Models so the first inference
        // call (typo classify, snippet expansion, Ask Halen) doesn't pay the
        // weight-load latency in front of the user.
        Task { @MainActor [backends] in
            await InferenceBackends.prewarmAll(backends)
        }

        let trusted = AXPermissions.isTrusted()
        state.permissionStatus = trusted ? .granted : .denied
        Log.info("AXIsProcessTrusted at startup: \(trusted)")

        if trusted {
            startObservers()
            return
        }

        AXPermissions.promptForTrust()

        permissionPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let nowTrusted = AXPermissions.isTrusted()
                self.state.permissionStatus = nowTrusted ? .granted : .denied
                if nowTrusted {
                    Log.info("Accessibility now trusted — starting observers")
                    self.startObservers()
                    return
                }
            }
        }
    }

    /// Set once `shutdown()` has begun, observed by `AppDelegate` so a second
    /// "Quit" press during the async ladder doesn't kick off a parallel one.
    private(set) var isShuttingDown = false

    /// Synchronous teardown — kept for backwards compatibility with the
    /// in-process pieces that don't need async work. Out-of-process cleanup
    /// (plugin host, WS clients) requires `shutdown()` below.
    func stop() {
        Log.info("Halen stopping")
        isStopped = true
        permissionPollTask?.cancel()
        eventLogTask?.cancel()
        // Stop plugins explicitly so background tasks, hotkeys, and panels
        // unwind cleanly before the process exits.
        for plugin in registry.plugins {
            plugin.stop()
        }
        webSocketBridge?.stop()
        caretObserver?.stop()
        overlay?.stop()
    }

    /// Async cleanup — runs the out-of-process plugin shutdown ladder
    /// (shutdown → exit → SIGTERM → SIGKILL) and only returns once every
    /// plugin process is dead or unresponsive past its grace period. Called
    /// from `applicationShouldTerminate` with a `.terminateLater` reply so
    /// the process doesn't exit before this finishes.
    func shutdown() async {
        if isShuttingDown { return }
        isShuttingDown = true
        Log.info("Halen shutdown: async ladder")
        if let pluginHost {
            await pluginHost.stop()
        }
        stop()
    }

    private func startObservers() {
        guard !isStopped else { return }
        // Re-entrancy guard: `start()` and the permission-poll path can both
        // race to call this if AX permission flips during launch. Without the
        // guard the previous CaretObserver, OverlayController and all six
        // registered plugins would silently leak (the old refs overwritten,
        // their AXObserver run-loop sources and event-subscription tasks still
        // running). One call is enough.
        guard caretObserver == nil else { return }
        Log.info("Starting observers and plugin registry")

        let observer = CaretObserver(eventBus: eventBus)
        observer.start()
        caretObserver = observer

        let overlayCtrl = OverlayController(eventBus: eventBus)
        overlayCtrl.start()
        overlay = overlayCtrl

        let services = HalenServices(
            eventBus: eventBus,
            inference: inference,
            caretObserver: observer,
            calendar: CalendarService(),
            appSupportDir: HalenServices.defaultAppSupportDir()
        )

        // Register first-party plugins. Meeting Prep is no longer built in —
        // it ships as an out-of-process plugin (plugins/meeting-prep/),
        // installable from the Plugin Store, so the calendar capability and
        // its briefing logic live behind the JSON-RPC boundary like any
        // third-party plugin.
        registry.register(AskHalen(services: services))
        registry.register(TypoFixer(services: services, store: typoStore))
        registry.register(SentimentGuard(services: services))
        registry.register(VoiceDictation(services: services))
        registry.register(SnippetExpander(services: services))
        registry.register(BurnoutCopilot(services: services))

        // Out-of-process plugins under ~/Library/Application Support/Halen/Plugins/.
        // Discover manifests synchronously (just filesystem scan + JSON parse),
        // register each as an `ExternalPluginAdapter` so the marketplace
        // shows them with toggle + permissions + status alongside first-
        // party plugins. The actual subprocess spawn happens via the
        // registry's `start()` call on each adapter, which routes to
        // `PluginHost.spawn(...)`.
        let host = PluginHost(services: services)
        pluginHost = host
        for (dir, manifest) in host.discoverManifests() {
            let adapter = ExternalPluginAdapter(manifest: manifest, pluginDir: dir, host: host)
            registry.register(adapter)
        }
        host.startEventDispatcher()

        // Browser extensions (and any future loopback client) connect over
        // this WS server. Bound to 127.0.0.1 only. The user can turn the
        // bridge off in Settings — start only when enabled.
        let ws = WebSocketBridge(services: services)
        webSocketBridge = ws
        if WebSocketBridge.isEnabledInDefaults {
            ws.start()
        }
    }

    /// Register a freshly-installed external plugin live, without an app
    /// restart. Called by the Plugin Store after `PluginInstaller` has
    /// downloaded, unpacked, and validated the plugin into the install root.
    /// No-op if the plugin host hasn't been created yet (Accessibility not
    /// granted) — in that path the plugin is picked up by the normal
    /// `discoverManifests()` scan once observers start.
    func registerInstalledPlugin(directory: URL, manifest: PluginManifest) {
        guard let pluginHost else {
            Log.warn("AppCoordinator: plugin host not ready; \(manifest.id) will load on next launch")
            return
        }
        guard !registry.contains(manifest.id) else { return }
        let adapter = ExternalPluginAdapter(manifest: manifest, pluginDir: directory, host: pluginHost)
        registry.register(adapter)
    }

    private func startEventLogger() {
        eventLogTask = Task { @MainActor [eventBus] in
            for await event in eventBus.subscribe() {
                switch event {
                case .appFocused(let payload):
                    Log.info("evt app.focused \(payload.appName)")
                case .textPaused(let payload):
                    // Never write the user's text (or any prefix of it) to the
                    // system log. `Log.redact` emits an unforgeable fingerprint
                    // good enough to correlate two events involving the same
                    // content but not reverse-engineer the content itself.
                    Log.info("evt text.pause app=\(payload.appName) chars=\(payload.text.count) offset=\(payload.caretOffset) text=\(Log.redact(payload.text))")
                case .caretMoved(let payload):
                    // `.debug` — this fires on every typing burst; keeping it
                    // at `.info` put a log line in the unified system log per
                    // keystroke-group, a measurable idle cost. The overlay
                    // indicator is confirmed working; `caret.moved skipped`
                    // in CaretObserver still logs at `.info` if bounds fail.
                    Log.debug("evt caret.moved \(Int(payload.rect.x)),\(Int(payload.rect.y)) \(Int(payload.rect.width))x\(Int(payload.rect.height))")
                case .inferenceActivity(let payload):
                    Log.debug("evt inference.activity \(payload.phase.rawValue) source=\(payload.source)")
                }
            }
        }
    }
}
