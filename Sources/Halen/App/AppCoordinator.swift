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

    /// Kept around so we can prewarm Apple FM at launch and re-probe
    /// availability from the Settings UI without going through the router.
    let backends: [InferenceBackend]

    private var caretObserver: CaretObserver?
    private var overlay: OverlayController?
    private var pluginHost: PluginHost?
    private var webSocketBridge: WebSocketBridge?

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
            appSupportDir: HalenServices.defaultAppSupportDir()
        )

        // Register first-party plugins.
        registry.register(AskHalen(services: services))
        registry.register(TypoFixer(services: services, store: typoStore))
        registry.register(SentimentGuard(services: services))
        registry.register(VoiceDictation(services: services))
        registry.register(SnippetExpander(services: services))
        registry.register(BurnoutCopilot(services: services))
        registry.register(MeetingPrep(services: services))

        // Spin up any out-of-process plugins under
        // ~/Library/Application Support/Halen/Plugins/. Discovery + spawn is
        // async — happens off the launch path so a slow or hung plugin can't
        // block Halen from coming up. The host is idempotent: a 0-plugin
        // install just logs and returns.
        let host = PluginHost(services: services)
        pluginHost = host
        Task { await host.start() }

        // Browser extensions (and any future loopback client) connect over
        // this WS server. Bound to 127.0.0.1 only.
        let ws = WebSocketBridge(services: services)
        webSocketBridge = ws
        ws.start()
    }

    private func startEventLogger() {
        eventLogTask = Task { @MainActor [eventBus] in
            for await event in eventBus.subscribe() {
                switch event {
                case .appFocused(let payload):
                    Log.info("evt app.focused \(payload.appName)")
                case .textPaused(let payload):
                    let preview = payload.text.prefix(40).replacingOccurrences(of: "\n", with: "↵")
                    Log.info("evt text.pause app=\(payload.appName) chars=\(payload.text.count) offset=\(payload.caretOffset) preview=\"\(preview)\"")
                case .caretMoved(let payload):
                    Log.debug("evt caret.moved \(Int(payload.rect.x)),\(Int(payload.rect.y)) \(Int(payload.rect.width))x\(Int(payload.rect.height))")
                case .inferenceActivity(let payload):
                    Log.debug("evt inference.activity \(payload.phase.rawValue) source=\(payload.source)")
                }
            }
        }
    }
}
