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
    let inference: InferenceClient = StubInferenceClient()

    private var permissionPollTask: Task<Void, Never>?
    private var caretObserver: CaretObserver?
    private var overlay: OverlayController?
    private var typoFixer: TypoFixer?
    private var eventLogTask: Task<Void, Never>?

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

        // Surfaces the system prompt that links to Privacy & Security → Accessibility.
        AXPermissions.promptForTrust()

        // Poll until granted. TCC has no notification mechanism for toggle changes.
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
        permissionPollTask?.cancel()
        eventLogTask?.cancel()
        typoFixer?.stop()
        caretObserver?.stop()
        overlay?.stop()
    }

    private func refreshPermissionStatus() {
        state.permissionStatus = AXPermissions.isTrusted() ? .granted : .denied
    }

    private func startObservers() {
        Log.info("Starting caret observer + overlay + typo fixer")
        let observer = CaretObserver(eventBus: eventBus)
        observer.start()
        caretObserver = observer

        let overlay = OverlayController(eventBus: eventBus)
        overlay.start()
        self.overlay = overlay

        let fixer = TypoFixer(eventBus: eventBus, caretObserver: observer)
        fixer.start()
        typoFixer = fixer
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
                case .textSaved, .clipboardChanged:
                    break
                }
            }
        }
    }
}
