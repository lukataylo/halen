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
    /// Downloader for the generation/rewrite model (Gemma 4 E4B). Surfaced
    /// to `SettingsView` so the user can trigger / observe / cancel it.
    let modelDownloader = ModelDownloader(spec: .gemma4E4B_IQ4_XS)
    /// Downloader for the dedicated classifier model (Qwen 2.5 0.5B). ~10×
    /// smaller than Gemma, so the first text.paused → popover stays in the
    /// sub-second range. Same SwiftUI-observable shape as `modelDownloader`.
    let classifierDownloader = ModelDownloader(spec: .qwen25_05B_Q4_K_M)
    let inference: RouterInferenceClient
    let typoStore = TypoStore()
    /// Per-app tone profiles — a host service (passed into `HalenServices`),
    /// not a plugin-owned store, so every writing plugin reads the same data.
    let toneProfileStore = AppToneProfileStore()
    /// In-memory list of apps focused this session. Powers the "recently
    /// used apps" picker in Settings → App tone profiles. App-coordinator
    /// scope so it accumulates across the Settings sheet's open/close
    /// cycle and survives the user navigating away from Settings.
    let recentApps = RecentAppsModel()
    private var recentAppsTask: Task<Void, Never>?
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

    /// First-run setup walkthrough. Lazy because building the SwiftUI
    /// hosting view shouldn't run on every launch — only when we actually
    /// need to present the flow (first launch, or the user re-triggers it
    /// from Settings → "Run setup again").
    lazy var onboardingWindow: OnboardingWindowController = {
        OnboardingWindowController(registry: registry)
    }()

    /// Sparkle-backed auto-update controller. Eager (not lazy) because
    /// Sparkle's daily check timer kicks in at app launch — we want the
    /// updater running before the user even opens the dropdown. Settings →
    /// About hosts the manual "Check for Updates…" button.
    let updater = UpdaterController()

    /// Process-wide hotkey-conflict tracker. Held here (rather than left
    /// as a private singleton) so the Settings UI can take a `@Bindable`
    /// reference and re-render when two plugins claim the same chord.
    let hotkeyConflicts = HotkeyConflictRegistry.shared

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
        // Eagerly load both bundled models (Qwen 0.5B classifier + Gemma 4
        // E4B generation) in parallel so the first user-facing inference —
        // typo classify, snippet expansion, sentiment / clarity check, Ask
        // Halen — doesn't pay the multi-second weight-load latency in front
        // of the user. Apple FM is prewarmed in the same task group.
        // Triggers downloads in the background too if either model is missing
        // (state surfaces through `modelDownloader.state` /
        // `classifierDownloader.state` for the Settings UI).
        Task { @MainActor [backends, modelDownloader, classifierDownloader] in
            if modelDownloader.state == .notDownloaded { modelDownloader.start() }
            if classifierDownloader.state == .notDownloaded { classifierDownloader.start() }
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
            toneProfiles: toneProfileStore,
            appSupportDir: HalenServices.defaultAppSupportDir()
        )

        // Register first-party plugins. Meeting Prep and Burnout Copilot are
        // no longer built in — they ship as out-of-process plugins
        // (plugins/meeting-prep/, plugins/burnout-copilot/), installable from
        // the Plugin Store, with their privileged work (calendar, the break
        // prompt) behind the JSON-RPC boundary like any third-party plugin.
        registry.register(AskHalen(services: services))
        // Word Replacements merges the previous Typo Fixer + Style Guide
        // plugins. Both engines live underneath as separate objects so
        // their distinct UX patterns (silent inline vs popover) survive
        // the merge — the wrapper just starts/stops them together and
        // hosts a tabbed detail view.
        registry.register(WordReplacements(services: services, typoStore: typoStore))
        // Writing Coach merges the previous Sentiment Guard + Clarity
        // Checker plugins. Same wrapper pattern as Word Replacements.
        registry.register(WritingCoach(services: services))
        registry.register(VoiceDictation(services: services))
        // Snippet Expander now also handles the email-reply action — see
        // EmailReplyDrafter + the ;reply built-in trigger + the ⌃⌥E
        // hotkey installed in SnippetExpander.start().
        registry.register(SnippetExpander(services: services))
        registry.register(Autocomplete(services: services))

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

        // First-run setup walkthrough. The registry is now populated, so
        // the "Pick what's on" step has live data to render. Defer one tick
        // so the AppKit run loop is fully up — opening a window during
        // didFinishLaunching can race with the menubar status item.
        if !OnboardingWindowController.isCompleted {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.onboardingWindow.present()
            }
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
        eventLogTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                switch event {
                case .appFocused(let payload):
                    Log.info("evt app.focused \(payload.appName)")
                    // Feed the recently-focused-apps list used by the
                    // Settings → App tone profiles editor. Lives on the
                    // coordinator (previously inside the ToneProfiles
                    // plugin) so it accumulates whether or not the
                    // editor is open.
                    self?.recentApps.note(bundleId: payload.appBundleId,
                                          name: payload.appName)
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
                case .findingDetected(let payload):
                    Log.info("evt finding.detected source=\(payload.source) severity=\(payload.severity.rawValue) summary=\"\(payload.summary)\"")
                case .findingsCleared(let payload):
                    Log.info("evt findings.cleared source=\(payload.source) id=\(payload.id ?? "*")")
                case .findingActionRequested(let payload):
                    Log.info("evt finding.action source=\(payload.source) action=\(payload.action.rawValue)")
                }
            }
        }
    }
}
