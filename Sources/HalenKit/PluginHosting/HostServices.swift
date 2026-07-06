import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UserNotifications
import HalenPluginAPI

/// Owns every shared host service and mints capability-gated
/// `PluginContext`s from plugin manifests. One instance per app, built by
/// `AppCoordinator` once accessibility observers are up.
///
/// The gating rule lives in exactly one place — `makeContext` — so the
/// permissions screen, the manifest, and the runtime can't disagree about
/// what a plugin can touch.
@MainActor
package final class HostServices {
    package let eventBus: EventBus
    package let inference: RouterInferenceClient
    package let caretObserver: CaretObserver
    package let broker: PermissionBroker
    package let toneProfiles: AppToneProfileStore
    package let recentApps: RecentAppsModel
    package let snippets: SnippetStore
    package let calendar: CalendarService
    package let notchManager: NotchPanelManager
    package let appSupportDir: URL

    /// Backs `ui.prompt` — one shared presenter so a second prompt
    /// supersedes the first rather than stacking popups.
    let promptPresenter = PluginPromptPresenter()

    package init(eventBus: EventBus,
                 inference: RouterInferenceClient,
                 caretObserver: CaretObserver,
                 broker: PermissionBroker,
                 toneProfiles: AppToneProfileStore,
                 recentApps: RecentAppsModel,
                 snippets: SnippetStore,
                 calendar: CalendarService,
                 appSupportDir: URL) {
        self.eventBus = eventBus
        self.inference = inference
        self.caretObserver = caretObserver
        self.broker = broker
        self.toneProfiles = toneProfiles
        self.recentApps = recentApps
        self.snippets = snippets
        self.calendar = calendar
        self.notchManager = NotchPanelManager()
        self.appSupportDir = appSupportDir
    }

    /// Build the capability-gated context for one plugin. Call again after a
    /// grant change (the registry restarts the plugin with the new context).
    package func makeContext(for manifest: PluginManifest) -> PluginContext {
        let granted = broker.effectiveCapabilities(for: manifest)

        let text: TextService? =
            granted.contains(.observeText) || granted.contains(.insertText)
            ? HostTextService(caretObserver: caretObserver,
                              canObserve: granted.contains(.observeText),
                              canInsert: granted.contains(.insertText))
            : nil

        let ui: UIService? =
            granted.contains(.popoverUI) || granted.contains(.notifications)
            ? HostUIService(presenter: promptPresenter,
                            canPrompt: granted.contains(.popoverUI),
                            canToast: granted.contains(.notifications))
            : nil

        return PluginContext(
            pluginId: manifest.id,
            events: HostEventsService(bus: eventBus, manifest: manifest, granted: granted),
            inference: inference,
            storage: HostStorageService(directory: appSupportDir.appending(path: manifest.id)),
            permissions: PluginPermissionService(broker: broker),
            text: text,
            ui: ui,
            hotkeys: granted.contains(.hotkeys)
                ? HostHotkeyService(ownerLabel: manifest.name) : nil,
            clipboard: granted.contains(.clipboard) ? HostClipboardService() : nil,
            speech: granted.contains(.speak) ? HostSpeechService() : nil,
            shortcuts: granted.contains(.runShortcuts) ? HostShortcutsService() : nil,
            screen: granted.contains(.observeScreen) ? HostScreenService() : nil,
            notch: granted.contains(.notchOverlay)
                ? NotchSurfaceGate(manager: notchManager, pluginId: manifest.id) : nil,
            toneProfiles: granted.contains(.toneProfiles) ? toneProfiles : nil,
            recentApps: granted.contains(.toneProfiles) ? recentApps : nil,
            snippets: granted.contains(.snippets) ? snippets : nil
        )
    }
}

// MARK: - Events

/// Fans the host bus out to one plugin, filtered by (a) the manifest's
/// declared `events` topics and (b) the observation capabilities backing
/// each topic. Same semantics as the external stdio path.
final class HostEventsService: EventsService {
    private let bus: EventBus
    private let allowedTopics: Set<String>

    init(bus: EventBus, manifest: PluginManifest, granted: Set<Capability>) {
        self.bus = bus
        var allowed = Set(manifest.events ?? [])
        // Topic → capability backing it. An undeclared/revoked capability
        // silently removes its topics: the plugin just never hears them.
        if !granted.contains(.observeText) {
            allowed.remove("text.pause")
            allowed.remove("caret.moved")
        }
        if !granted.contains(.observeApps) {
            allowed.remove("app.focused")
        }
        self.allowedTopics = allowed
    }

    func subscribe() -> AsyncStream<Event> {
        let upstream = bus.subscribe()
        let allowed = allowedTopics
        return AsyncStream { continuation in
            let task = Task {
                for await event in upstream {
                    if allowed.contains(event.method) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func publish(_ event: Event) {
        // Only the host observes the system: plugin-sourced topics pass,
        // host-sourced ones are dropped so a plugin can't forge a text event.
        switch event {
        case .textPaused, .caretMoved, .appFocused:
            Log.warn("EventsService: dropped plugin-published host topic \(event.method)")
        case .inferenceActivity, .findingDetected, .findingsCleared, .findingActionRequested:
            bus.publish(event)
        }
    }
}

// MARK: - Text

@MainActor
final class HostTextService: TextService {
    private weak var caretObserver: CaretObserver?
    private let canObserve: Bool
    private let canInsert: Bool

    init(caretObserver: CaretObserver, canObserve: Bool, canInsert: Bool) {
        self.caretObserver = caretObserver
        self.canObserve = canObserve
        self.canInsert = canInsert
    }

    var focusedElement: AXUIElement? {
        guard canObserve || canInsert else { return nil }
        return caretObserver?.currentElement
    }

    @discardableResult
    func replaceRange(_ range: NSRange, with replacement: String, describedAs description: String?) -> Bool {
        guard canInsert, let caretObserver else { return false }
        return caretObserver.replaceRange(range, with: replacement, describedAs: description)
    }

    @discardableResult
    func replaceRange(_ range: NSRange, with replacement: String, in element: AXUIElement, describedAs description: String?) -> Bool {
        guard canInsert, let caretObserver else { return false }
        return caretObserver.replaceRange(range, with: replacement, in: element, describedAs: description)
    }

    @discardableResult
    func pasteFallback(text: String, deleteCount: Int) -> Bool {
        guard canInsert else { return false }
        return CaretObserver.pasteFallback(text: text, deleteCount: deleteCount)
    }

    func caretBounds() -> CGRect? {
        guard let element = focusedElement else { return nil }
        return axReadCaretBounds(element)
    }
}

// MARK: - UI

@MainActor
final class HostUIService: UIService {
    private let presenter: PluginPromptPresenter
    private let canPrompt: Bool
    private let canToast: Bool

    init(presenter: PluginPromptPresenter, canPrompt: Bool, canToast: Bool) {
        self.presenter = presenter
        self.canPrompt = canPrompt
        self.canToast = canToast
    }

    func toast(title: String, body: String) {
        guard canToast else {
            Log.warn("UIService: toast dropped — notifications capability not granted")
            return
        }
        Log.info("toast: \(title): \(body)")
        Task { await NotificationPoster.post(title: title, body: body) }
    }

    func prompt(title: String, body: String, actions: [String], timeoutSeconds: Double?) async -> String? {
        guard canPrompt else {
            Log.warn("UIService: prompt dropped — popover-ui capability not granted")
            return nil
        }
        return await presenter.prompt(title: title, body: body,
                                      actions: actions, timeoutSeconds: timeoutSeconds)
    }
}

/// Post a transient system notification. Requests authorisation on first
/// use; if the user has denied it the `add` call fails silently — callers
/// keep their own log line as the paper trail.
enum NotificationPoster {
    static func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        try? await center.add(request)
    }
}

// MARK: - Hotkeys

/// Per-plugin hotkey table over `HotkeyRegistrar` (NSEvent monitors + the
/// process-wide conflict registry). One instance per plugin so
/// `unregisterAll()` can't touch anyone else's chords.
@MainActor
final class HostHotkeyService: HotkeyService {
    private let ownerLabel: String
    private var registrars: [String: HotkeyRegistrar] = [:]

    init(ownerLabel: String) {
        self.ownerLabel = ownerLabel
    }

    @discardableResult
    func register(id: String, keyCode: UInt32, modifiers: NSEvent.ModifierFlags,
                  onFire: @escaping @MainActor () -> Void) -> Bool {
        // Re-registering the same id replaces the previous chord.
        registrars.removeValue(forKey: id)?.unregister()
        let registrar = HotkeyRegistrar()
        let ok = registrar.register(keyCode: keyCode,
                                    modifiers: Self.carbonMask(cocoa: modifiers),
                                    owner: ownerLabel,
                                    onFire: onFire)
        if ok { registrars[id] = registrar }
        return ok
    }

    func unregister(id: String) {
        registrars.removeValue(forKey: id)?.unregister()
    }

    func unregisterAll() {
        for (_, registrar) in registrars { registrar.unregister() }
        registrars.removeAll()
    }

    /// `HotkeyRegistrar` still speaks Carbon masks (its call sites predate
    /// the NSEvent rewrite); the public API speaks `NSEvent.ModifierFlags`.
    private static func carbonMask(cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if cocoa.contains(.control) { mask |= UInt32(controlKey) }
        if cocoa.contains(.option)  { mask |= UInt32(optionKey) }
        if cocoa.contains(.shift)   { mask |= UInt32(shiftKey) }
        if cocoa.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }
}

// MARK: - Storage

final class HostStorageService: StorageService, @unchecked Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func readJSON<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = directory.appending(path: filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func writeJSON<T: Encodable>(_ value: T, to filename: String) {
        let url = directory.appending(path: filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Clipboard

@MainActor
final class HostClipboardService: ClipboardService {
    func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func write(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Speech

@MainActor
final class HostSpeechService: SpeechService {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - Shortcuts

final class HostShortcutsService: ShortcutsService, @unchecked Sendable {
    enum ShortcutError: Error, LocalizedError {
        case failed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .failed(let code, let stderr):
                return "Shortcut failed (exit \(code)): \(stderr)"
            }
        }
    }

    func run(name: String, input: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["run", name]
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                if let input {
                    let stdin = Pipe()
                    process.standardInput = stdin
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    stdin.fileHandleForWriting.closeFile()
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                         encoding: .utf8) ?? ""
                        continuation.resume(throwing: ShortcutError.failed(
                            exitCode: process.terminationStatus, stderr: err))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Screen

@MainActor
final class HostScreenService: ScreenService {
    enum ScreenError: Error, LocalizedError {
        case noDisplay
        case notPermitted

        var errorDescription: String? {
            switch self {
            case .noDisplay:    return "No display available to capture"
            case .notPermitted: return "Screen Recording is not granted in System Settings"
            }
        }
    }

    func captureMainDisplay() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenError.notPermitted }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw ScreenError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }
}
