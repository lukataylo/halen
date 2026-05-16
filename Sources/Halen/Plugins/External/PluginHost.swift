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
    private var instances: [PluginInstance] = []
    private var subscriptionTask: Task<Void, Never>?

    init(services: HalenServices) {
        self.services = services
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
                                          handler: { [weak self] method, params in
                guard let self else {
                    throw RPCErrorObject(code: PluginRPC.ErrorCode.internalError.rawValue,
                                         message: "Host gone away", data: nil)
                }
                return try await self.handleIncoming(method: method, params: params,
                                                    fromPlugin: manifest.id)
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

    private func dispatch(_ event: Event) {
        // Map each Event case into a (topic, payload) pair the plugin sees.
        // The topic strings match the `events` array entries plugins declare
        // in their manifest.
        let topic: String
        let payload: RPCValue
        switch event {
        case .textPaused(let p):
            topic = "text.pause"
            payload = .object([
                "appBundleId": p.appBundleId,
                "appName": p.appName,
                "text": p.text,
                "caretOffset": p.caretOffset,
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?])
        case .caretMoved(let p):
            topic = "caret.moved"
            payload = .object([
                "appBundleId": p.appBundleId,
                "rect": [
                    "x": p.rect.x, "y": p.rect.y,
                    "width": p.rect.width, "height": p.rect.height
                ],
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?])
        case .appFocused(let p):
            topic = "app.focused"
            payload = .object([
                "appBundleId": p.appBundleId,
                "appName": p.appName,
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?])
        case .inferenceActivity:
            // Internal host signal — don't forward, would just cause loops
            // when plugins respond to inference and trigger more activity.
            return
        }

        for instance in instances {
            instance.deliver(event: topic, payload: payload)
        }
    }

    // MARK: - Plugin → host RPC bridge

    /// Single dispatch site for all plugin→host calls. Method names use the
    /// slash namespace from the protocol spec.
    private func handleIncoming(method: String, params: RPCValue?, fromPlugin pluginId: String) async throws -> RPCValue {
        switch method {
        case "inference/complete":
            return try await handleInferenceComplete(params: params)
        case "ax/replaceRange":
            return try await handleAXReplaceRange(params: params)
        case "ax/readSelection":
            return try await handleAXReadSelection()
        case "ui/toast":
            return try await handleUIToast(params: params, fromPlugin: pluginId)
        default:
            throw RPCErrorObject(code: PluginRPC.ErrorCode.methodNotFound.rawValue,
                                 message: "Unknown host method: \(method)",
                                 data: nil)
        }
    }

    private func handleInferenceComplete(params: RPCValue?) async throws -> RPCValue {
        guard let obj = params?.objectValue,
              let prompt = obj["prompt"]?.stringValue else {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.invalidParams.rawValue,
                                 message: "inference/complete requires `prompt`",
                                 data: nil)
        }
        let tierString = obj["tier"]?.stringValue ?? "medium"
        let tier = ModelTier(rawValue: tierString) ?? .medium
        let maxTokens = obj["maxTokens"]?.intValue ?? 256
        let temperature = (obj["temperature"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }) ?? 0.4
        let stop = obj["stop"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let taskKindString = obj["taskKind"]?.stringValue ?? "generation"
        let taskKind = InferenceTaskKind(rawValue: taskKindString) ?? .generation

        let request = InferenceRequest(prompt: prompt, tier: tier,
                                       maxTokens: maxTokens, temperature: temperature,
                                       stop: stop, taskKind: taskKind)
        do {
            let response = try await services.inference.complete(request)
            return .object([
                "text": response.text,
                "modelId": response.modelId,
                "latencyMs": response.latencyMs
            ] as [String: Any?])
        } catch {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.inferenceUnavailable.rawValue,
                                 message: error.localizedDescription,
                                 data: nil)
        }
    }

    private func handleAXReplaceRange(params: RPCValue?) async throws -> RPCValue {
        guard let obj = params?.objectValue,
              let replacement = obj["text"]?.stringValue else {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.invalidParams.rawValue,
                                 message: "ax/replaceRange requires `text`", data: nil)
        }
        let location = obj["location"]?.intValue ?? 0
        let length = obj["length"]?.intValue ?? 0
        let range = NSRange(location: location, length: length)
        let ok = services.caretObserver.replaceRange(range, with: replacement)
        if !ok {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.axWriteFailed.rawValue,
                                 message: "AX write returned false (no focused element, or app refused)",
                                 data: nil)
        }
        return .object(["ok": true] as [String: Any?])
    }

    private func handleAXReadSelection() async throws -> RPCValue {
        guard let element = services.caretObserver.currentElement else {
            return .object([
                "text": RPCValue.null,
                "appBundleId": RPCValue.null
            ])
        }
        let selection = axReadString(element, kAXSelectedTextAttribute) ?? ""
        let appBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return .object([
            "text": selection,
            "appBundleId": appBundleId
        ] as [String: Any?])
    }

    private func handleUIToast(params: RPCValue?, fromPlugin pluginId: String) async throws -> RPCValue {
        let title = params?.objectValue?["title"]?.stringValue ?? pluginId
        let body = params?.objectValue?["body"]?.stringValue ?? ""
        Log.info("plugin-toast[\(pluginId)] \(title): \(body)")
        // Real UNUserNotification + overlay surfacing comes in a later milestone;
        // for now the log line is the visible artifact, which is enough to
        // prove the round-trip end-to-end.
        return .object(["ok": true] as [String: Any?])
    }
}
