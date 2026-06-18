import Foundation
import AppKit
import ApplicationServices
import UserNotifications

/// Single source of truth for every plugin/extension → host JSON-RPC method
/// the host exposes. Both transports (stdio via `PluginHost` and WebSocket
/// via `WebSocketBridge`) delegate every incoming request to
/// `HostBridge.dispatch(...)` so the API surface is identical regardless of
/// how a client arrived.
///
/// This used to live duplicated in `PluginHost.handleIncoming` and
/// `WebSocketBridge.dispatch`, and the two had already drifted: the WS path
/// hardcoded `temperature: 0.4`, didn't accept `stop`/`taskKind`/`maxTokens`,
/// and was missing `ax/replaceRange` + `ui/toast` entirely. Consolidating
/// closes that class of bug.
@MainActor
final class HostBridge {
    private let services: HalenServices
    /// Backs the `ui/prompt` capability — one shared presenter so a second
    /// prompt supersedes the first rather than stacking popups.
    private let promptPresenter = PluginPromptPresenter()

    init(services: HalenServices) {
        self.services = services
    }

    /// The one dispatch site. Returns the `result` payload or throws an
    /// `RPCErrorObject` the transport then encodes back to the caller.
    ///
    /// `grantedPermissions` is the calling client's permission set — for a
    /// stdio plugin, its manifest's `permissions`; for the WebSocket bridge,
    /// empty (the browser extension has no privileged grants). Sensitive
    /// methods (currently `calendar/*`) are gated on it. The text/AX/inference
    /// methods stay ungated for now — tightening those is a separate security
    /// pass that would need every existing plugin to declare permissions.
    func dispatch(method: String,
                  params: RPCValue?,
                  grantedPermissions: Set<String>) async throws -> RPCValue {
        switch method {
        case "inference/complete":
            return try await inferenceComplete(params: params)
        case "ax/replaceRange":
            return try await axReplaceRange(params: params)
        case "ax/readSelection":
            return axReadSelection()
        case "ui/toast":
            return uiToast(params: params)
        case "ui/prompt":
            return await uiPrompt(params: params)
        case "calendar/upcomingEvents":
            try require("calendar", in: grantedPermissions, for: method)
            return try await calendarUpcomingEvents(params: params)
        case "calendar/createEvent":
            try require("calendar", in: grantedPermissions, for: method)
            return try await calendarCreateEvent(params: params)
        case "profile/getToneProfile":
            return profileGet(params: params)
        case "profile/setToneProfile":
            return profileSet(params: params)
        case "profile/listToneProfiles":
            return profileList()
        default:
            throw RPCErrorObject(code: PluginRPC.ErrorCode.methodNotFound.rawValue,
                                 message: "Unknown host method: \(method)", data: nil)
        }
    }

    /// Throw `permissionDenied` unless `permission` is in the caller's grant
    /// set. The plugin declared (or didn't) the permission in its manifest;
    /// the marketplace install sheet is where the user actually consents.
    private func require(_ permission: String,
                         in granted: Set<String>,
                         for method: String) throws {
        guard granted.contains(permission) else {
            throw RPCErrorObject(
                code: PluginRPC.ErrorCode.permissionDenied.rawValue,
                message: "\(method) requires the `\(permission)` permission — declare it in halen-plugin.json",
                data: nil)
        }
    }

    // MARK: - Methods

    private func inferenceComplete(params: RPCValue?) async throws -> RPCValue {
        guard let obj = params?.objectValue,
              let prompt = obj["prompt"]?.stringValue else {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.invalidParams.rawValue,
                                 message: "inference/complete requires `prompt`", data: nil)
        }
        let tier = ModelTier(rawValue: obj["tier"]?.stringValue ?? "medium") ?? .medium
        let maxTokens = obj["maxTokens"]?.intValue ?? 256
        let temperature = obj["temperature"]?.numericValue ?? 0.4
        let stop = obj["stop"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let taskKind = InferenceTaskKind(rawValue: obj["taskKind"]?.stringValue ?? "generation") ?? .generation

        let request = InferenceRequest(
            prompt: prompt, tier: tier,
            maxTokens: maxTokens, temperature: temperature,
            stop: stop, taskKind: taskKind
        )
        do {
            let response = try await services.inference.complete(request)
            return .object([
                "text": response.text,
                "modelId": response.modelId,
                "latencyMs": response.latencyMs
            ] as [String: Any?])
        } catch {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.inferenceUnavailable.rawValue,
                                 message: error.localizedDescription, data: nil)
        }
    }

    private func axReplaceRange(params: RPCValue?) async throws -> RPCValue {
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

    private func axReadSelection() -> RPCValue {
        guard let element = services.caretObserver.currentElement else {
            return .object([
                "text": RPCValue.null,
                "appBundleId": RPCValue.null,
                "location": RPCValue.null,
                "length": RPCValue.null
            ])
        }
        let selection = axReadString(element, kAXSelectedTextAttribute) ?? ""
        let appBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Expose the selection range so a plugin that wants to rewrite the
        // selection in place can pass (location, length) straight to
        // `ax/replaceRange`. Without this, (0, 0) means "insert at the start
        // of the field" — surprising for callers that expect "replace what's
        // selected". Added for the Desktop Buddy plugin's rewrite mode.
        let range = axReadSelectedRange(element)
        var result: [String: Any?] = [
            "text": selection,
            "appBundleId": appBundleId,
            "location": nil,
            "length": nil
        ]
        if let range {
            result["location"] = range.location
            result["length"] = range.length
        }
        return .object(result)
    }

    private func uiToast(params: RPCValue?) -> RPCValue {
        let title = params?.objectValue?["title"]?.stringValue ?? "Halen"
        let body = params?.objectValue?["body"]?.stringValue ?? ""
        // `ui/toast` posts a real system notification (it used to only log).
        // No permission gate: a notification is low-risk and the user can
        // silence Halen's notifications in System Settings. Authorisation is
        // requested lazily — the first toast triggers the one-time prompt.
        Log.info("toast: \(title): \(body)")
        Task { await Self.postNotification(title: title, body: body) }
        return .object(["ok": true] as [String: Any?])
    }

    /// Post a transient system notification. Used by `ui/toast`. Requests
    /// authorisation on first use; if the user has denied it the `add` call
    /// fails silently — the log line above is still the paper trail.
    nonisolated static func postNotification(title: String, body: String) async {
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

    /// Interactive popup. Unlike `ui/toast` this *blocks* the plugin's RPC
    /// call until the user picks an action (or dismisses / it times out).
    /// Ungated — like `ui/toast`, a popup is an annoyance at worst, not a
    /// privilege; marketplace curation is the real gate on hostile plugins.
    private func uiPrompt(params: RPCValue?) async -> RPCValue {
        let obj = params?.objectValue
        let title = obj?["title"]?.stringValue ?? "Halen"
        let body = obj?["body"]?.stringValue ?? ""
        let actions = obj?["actions"]?.arrayValue?.compactMap { $0.stringValue } ?? ["OK"]
        // Optional: let the plugin cap the popup's lifetime so it expires in
        // step with the plugin's own RPC timeout (e.g. Mother's confront window)
        // instead of lingering for the full 300s default after the plugin acts.
        let timeoutSeconds = obj?["timeoutSeconds"]?.doubleValue
        let choice = await promptPresenter.prompt(title: title, body: body,
                                                  actions: actions,
                                                  timeoutSeconds: timeoutSeconds)
        // `action` is the chosen string, or null on dismiss / timeout.
        return .object(["action": choice] as [String: Any?])
    }

    // MARK: - Tone profiles
    //
    // The host owns `AppToneProfileStore` as a shared `HalenServices`
    // member because Writing Coach (tone + clarity classifiers) and the
    // ;reply / ⌃⌥E email-reply action in Snippet Expander both read it
    // on every classification. Exposing the store over RPC lets an
    // external plugin edit the *same* data the in-process readers see.
    //
    // Ungated for now. A future security pass might gate writes on a
    // `profiles` permission, but for v0.2.0 the data is per-user
    // preference (formal vs casual register, not a privacy-sensitive
    // signal) and the marketplace is the trust boundary.

    private func profileGet(params: RPCValue?) -> RPCValue {
        let bundleId = params?.objectValue?["bundleId"]?.stringValue ?? ""
        let profile = services.toneProfiles.profile(for: bundleId)
        return .object([
            "tone": profile.rawValue,
            "label": profile.label,
            "promptClause": profile.promptClause
        ] as [String: Any?])
    }

    private func profileSet(params: RPCValue?) -> RPCValue {
        guard let obj = params?.objectValue,
              let bundleId = obj["bundleId"]?.stringValue,
              let toneRaw = obj["tone"]?.stringValue,
              let tone = ToneProfile(rawValue: toneRaw) else {
            // Invalid input is a JSON-RPC "method failed" rather than a
            // protocol-level error — return ok: false with a hint so the
            // plugin can surface a readable error.
            return .object([
                "ok": false,
                "error": "profile/setToneProfile requires `bundleId` and a valid `tone` (formal|casual|neutral)"
            ] as [String: Any?])
        }
        services.toneProfiles.setProfile(tone, for: bundleId)
        return .object(["ok": true] as [String: Any?])
    }

    private func profileList() -> RPCValue {
        let entries = services.toneProfiles.sortedEntries.map { entry -> RPCValue in
            .object([
                "bundleId": entry.bundleId,
                "tone": entry.profile.rawValue,
                "label": entry.profile.label
            ] as [String: Any?])
        }
        return .object(["profiles": RPCValue.array(entries)] as [String: Any?])
    }

    // MARK: - Calendar (gated on the `calendar` permission)

    private func calendarUpcomingEvents(params: RPCValue?) async throws -> RPCValue {
        let obj = params?.objectValue
        let withinHours = obj?["withinHours"]?.numericValue ?? 24
        let max = obj?["max"]?.intValue ?? 20

        // Lazily request access on first use — the host owns the one TCC
        // prompt; the plugin never sees EventKit directly.
        guard await services.calendar.requestAccess() else {
            throw RPCErrorObject(
                code: PluginRPC.ErrorCode.permissionDenied.rawValue,
                message: "Calendar access not granted in System Settings → Privacy & Security",
                data: nil)
        }
        let events = services.calendar.upcomingEvents(withinHours: withinHours, max: max)
        return .object(["events": RPCValue.array(events.map(\.rpcObject))] as [String: Any?])
    }

    private func calendarCreateEvent(params: RPCValue?) async throws -> RPCValue {
        guard let obj = params?.objectValue,
              let title = obj["title"]?.stringValue,
              let start = obj["start"]?.numericValue else {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.invalidParams.rawValue,
                                 message: "calendar/createEvent requires `title` and `start` (epoch seconds)",
                                 data: nil)
        }
        let durationMinutes = obj["durationMinutes"]?.intValue ?? 30

        guard await services.calendar.requestAccess() else {
            throw RPCErrorObject(
                code: PluginRPC.ErrorCode.permissionDenied.rawValue,
                message: "Calendar access not granted in System Settings → Privacy & Security",
                data: nil)
        }
        guard let id = services.calendar.createEvent(
            title: title,
            start: Date(timeIntervalSince1970: start),
            durationMinutes: durationMinutes)
        else {
            throw RPCErrorObject(code: PluginRPC.ErrorCode.internalError.rawValue,
                                 message: "Failed to create the calendar event", data: nil)
        }
        return .object(["id": id] as [String: Any?])
    }
}

// MARK: - Event broadcast helper

extension Event {
    /// Map an in-process `Event` to the `(topic, payload)` shape both the
    /// stdio plugin host and the WebSocket bridge push to their clients.
    /// `nil` for events the protocol deliberately doesn't expose (today:
    /// `inferenceActivity` — internal signal that would just cause loops
    /// when plugins respond to inference and trigger more activity events).
    func toBroadcast() -> (topic: String, payload: RPCValue)? {
        switch self {
        case .textPaused(let p):
            return ("text.pause", .object([
                "appBundleId": p.appBundleId,
                "appName": p.appName,
                "text": p.text,
                "caretOffset": p.caretOffset,
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?]))
        case .caretMoved(let p):
            return ("caret.moved", .object([
                "appBundleId": p.appBundleId,
                "rect": ["x": p.rect.x, "y": p.rect.y,
                         "width": p.rect.width, "height": p.rect.height],
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?]))
        case .appFocused(let p):
            return ("app.focused", .object([
                "appBundleId": p.appBundleId,
                "appName": p.appName,
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?]))
        case .inferenceActivity:
            return nil
        case .findingDetected(let p):
            // Originally not broadcast — the concern was a plugin re-emitting
            // findings in response to other plugins' findings, creating
            // feedback loops. The mitigation now is that re-emitting a
            // finding from a plugin requires a host method that doesn't
            // exist (`finding/publish` isn't in the protocol), so subscribing
            // is read-only by construction. Exposing the events lets external
            // Autocomplete suppress its ghost suggestions when other writing
            // plugins are flagging the paragraph — the UX-3 behaviour it had
            // in-process.
            return ("finding.detected", .object([
                "source": p.source,
                "id": p.id,
                "severity": p.severity.rawValue,
                "summary": p.summary,
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?]))
        case .findingsCleared(let p):
            return ("finding.cleared", .object([
                "source": p.source,
                "id": p.id as Any?,
                "timestamp": p.timestamp.timeIntervalSince1970
            ] as [String: Any?]))
        case .findingActionRequested:
            // Plugin-targeted action requests (e.g. "user clicked Rephrase
            // on a SentimentGuard finding") are still internal — they're
            // addressed at a specific plugin id, not a broadcast.
            return nil
        }
    }
}

// MARK: - RPCValue numeric convenience

extension RPCValue {
    /// Returns the value as `Double` whether the JSON encoded it as an int or
    /// a float. Avoids a tedious `if case let .int / if case let .double` at
    /// every numeric param parse site.
    var numericValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        default:             return nil
        }
    }
}
