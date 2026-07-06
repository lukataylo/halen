import Foundation
import Observation
import HalenKit
import HalenPluginAPI
import WritingAssistantPlugin
import SnippetExpanderPlugin
import VoiceDictationPlugin
import PromptPolishPlugin
import MotherPlugin
import NotchBossPlugin

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
    /// The one permission layer: capability grants per plugin + every TCC
    /// prompt. Surfaced to the Permissions screen.
    let broker = PermissionBroker()
    /// Per-app tone profiles — host-owned so every writing plugin reads the
    /// same data. Handed to plugins via the `tone-profiles` capability.
    let toneProfileStore = AppToneProfileStore()
    /// In-memory list of apps focused this session, for the per-app tone
    /// picker. App-coordinator scope so it accumulates across panel opens.
    let recentApps = RecentAppsModel()
    /// Host-owned snippet library, handed to plugins via the `snippets`
    /// capability. The file stays at its pre-pivot path so existing users
    /// keep their snippets.
    let snippetStore = SnippetStore(
        fileURL: HalenSupportDirectory.subdirectory("com.halen.snippet-expander")
            .appending(path: "snippets.json"))
    let registry = PluginRegistry()
    /// Surfaced to Settings via HalenApp → HalenCenterView. Lives at app
    /// scope (not view scope) so its observable status survives the
    /// menubar popup closing and re-opening.
    let launchAtLogin = LaunchAtLoginController()

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
    /// Built in `startObservers()` once the caret observer exists; mints the
    /// capability-gated context for every plugin. Exposed to the Permissions
    /// screen so a grant toggle can rebuild the affected plugin.
    private(set) var hostServices: HostServices?

    /// First-party plugin recipes, so a plugin can be rebuilt with a fresh
    /// context after a capability grant changes.
    private var pluginFactories: [(manifest: PluginManifest,
                                   make: @MainActor (PluginContext) -> any HalenPlugin)] = []

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
        // E4B generation) in parallel so the first user-facing inference
        // doesn't pay the multi-second weight-load latency in front of the
        // user. Apple FM is prewarmed in the same task group. Triggers
        // downloads in the background too if either model is missing.
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
    /// (plugin host) requires `shutdown()` below.
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
        // race to call this if AX permission flips during launch. One call
        // is enough — see the leak analysis on the original implementation.
        guard caretObserver == nil else { return }
        Log.info("Starting observers and plugin registry")

        let observer = CaretObserver(eventBus: eventBus)
        observer.start()
        caretObserver = observer

        let overlayCtrl = OverlayController(eventBus: eventBus)
        overlayCtrl.start()
        overlay = overlayCtrl

        let host = HostServices(
            eventBus: eventBus,
            inference: inference,
            caretObserver: observer,
            broker: broker,
            toneProfiles: toneProfileStore,
            recentApps: recentApps,
            snippets: snippetStore,
            calendar: CalendarService(),
            appSupportDir: HalenSupportDirectory.root
        )
        hostServices = host

        // Adopt NotchBar users: if the separate app's droppings exist and the
        // user has never touched the Notch Boss toggle, default it on so
        // their approval doorbell keeps ringing after the migration.
        if UserDefaults.standard.object(forKey: "plugin.com.halen.notch-boss.enabled") == nil,
           FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.notchbar") {
            Log.info("NotchBar install detected — enabling Notch Boss by default")
            UserDefaults.standard.set(true, forKey: "plugin.com.halen.notch-boss.enabled")
        }

        // First-party plugins. Each is just another manifest + factory; the
        // context it receives is capability-gated exactly like an external
        // plugin's RPC surface.
        registerFirstParty(WritingAssistant.pluginManifest) { WritingAssistant(context: $0) }
        registerFirstParty(VoiceDictation.pluginManifest) { VoiceDictation(context: $0) }
        registerFirstParty(SnippetExpander.pluginManifest) { SnippetExpander(context: $0) }
        registerFirstParty(PromptPolish.pluginManifest) { PromptPolish(context: $0) }
        registerFirstParty(Mother.pluginManifest) { Mother(context: $0) }
        registerFirstParty(NotchBoss.pluginManifest) { NotchBoss(context: $0) }

        // Out-of-process plugins under ~/Library/Application Support/Halen/Plugins/.
        // Discover manifests synchronously (filesystem scan + JSON parse),
        // register each as an `ExternalPluginAdapter` so the plugin list
        // shows them with toggle + capabilities + status alongside first-
        // party plugins. The actual subprocess spawn happens via the
        // registry's `start()` call on each adapter.
        let external = PluginHost(services: host)
        pluginHost = external
        for (dir, manifest) in external.discoverManifests() {
            let adapter = ExternalPluginAdapter(manifest: manifest, pluginDir: dir, host: external)
            registry.register(adapter)
        }
        external.startEventDispatcher()

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

    private func registerFirstParty(_ manifest: PluginManifest,
                                    make: @escaping @MainActor (PluginContext) -> any HalenPlugin) {
        guard let hostServices else { return }
        pluginFactories.append((manifest, make))
        registry.register(make(hostServices.makeContext(for: manifest)))
    }

    /// Rebuild one first-party plugin with a freshly minted context. Called
    /// by the Permissions screen after a capability grant changes, so the
    /// plugin's services always match the grant table. External plugins
    /// don't need this — their capability set is re-read on every RPC call.
    func reloadPlugin(id: String) {
        guard let hostServices,
              let entry = pluginFactories.first(where: { $0.manifest.id == id }) else { return }
        registry.unregister(id)
        registry.register(entry.make(hostServices.makeContext(for: entry.manifest)))
    }

    /// Every registered plugin's manifest, for the Permissions screen.
    /// First-party manifests come from the factory table (present even
    /// before observers start); external ones from the registry.
    var allManifests: [PluginManifest] {
        var seen = Set<String>()
        var result: [PluginManifest] = []
        for entry in pluginFactories where seen.insert(entry.manifest.id).inserted {
            result.append(entry.manifest)
        }
        for plugin in registry.plugins where seen.insert(plugin.manifest.id).inserted {
            result.append(plugin.manifest)
        }
        return result
    }

    private func startEventLogger() {
        eventLogTask = Task { @MainActor [eventBus, weak self] in
            for await event in eventBus.subscribe() {
                switch event {
                case .appFocused(let payload):
                    Log.info("evt app.focused \(payload.appName)")
                    // Feed the recently-focused-apps list used by the
                    // Tone tab's per-app tone editor. Lives on the
                    // coordinator so it accumulates whether or not the
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
                    // keystroke-group, a measurable idle cost.
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
