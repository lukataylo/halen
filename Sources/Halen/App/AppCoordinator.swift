import Foundation
import Observation

@Observable
final class AppState {
    var permissionStatus: PermissionStatus = .unknown
    var lastEvent: String = "—"
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
    let inference: RouterInferenceClient
    let typoStore = TypoStore()
    let registry = PluginRegistry()

    private var caretObserver: CaretObserver?
    private var overlay: OverlayController?

    private var permissionPollTask: Task<Void, Never>?
    private var eventLogTask: Task<Void, Never>?
    /// Set once `stop()` runs, so a permission-poll tick that already passed its
    /// cancellation check can't still spin up observers after shutdown.
    private var isStopped = false

    init() {
        inference = RouterInferenceClient(
            backends: InferenceBackends.makeAll(),
            settings: inferenceSettings
        )
    }

    func start() {
        Log.info("Halen starting")
        startEventLogger()

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
        caretObserver?.stop()
        overlay?.stop()
    }

    private func startObservers() {
        guard !isStopped else { return }
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
        registry.register(TypoFixer(services: services, store: typoStore))
        registry.register(SentimentGuard(services: services))
        registry.register(VoiceDictation(services: services))
        registry.register(SnippetExpander(services: services))
        registry.register(BurnoutCopilot(services: services))
        registry.register(MeetingPrep(services: services))
    }

    private func startEventLogger() {
        eventLogTask = Task { @MainActor [eventBus] in
            for await event in eventBus.subscribe() {
                switch event {
                case .appFocused(let p):
                    Log.info("evt app.focused \(p.appName)")
                case .textPaused(let p):
                    let preview = p.text.prefix(40).replacingOccurrences(of: "\n", with: "↵")
                    Log.info("evt text.pause app=\(p.appName) chars=\(p.text.count) offset=\(p.caretOffset) preview=\"\(preview)\"")
                case .caretMoved(let p):
                    Log.debug("evt caret.moved \(Int(p.rect.x)),\(Int(p.rect.y)) \(Int(p.rect.width))x\(Int(p.rect.height))")
                case .inferenceActivity(let p):
                    Log.debug("evt inference.activity \(p.phase.rawValue) source=\(p.source)")
                case .textSaved, .clipboardChanged:
                    break
                }
            }
        }
    }
}
