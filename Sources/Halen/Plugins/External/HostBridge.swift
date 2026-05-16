import Foundation
import AppKit
import ApplicationServices

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

    init(services: HalenServices) {
        self.services = services
    }

    /// The one dispatch site. Returns the `result` payload or throws an
    /// `RPCErrorObject` the transport then encodes back to the caller.
    func dispatch(method: String, params: RPCValue?) async throws -> RPCValue {
        switch method {
        case "inference/complete":
            return try await inferenceComplete(params: params)
        case "ax/replaceRange":
            return try await axReplaceRange(params: params)
        case "ax/readSelection":
            return axReadSelection()
        case "ui/toast":
            return uiToast(params: params)
        default:
            throw RPCErrorObject(code: PluginRPC.ErrorCode.methodNotFound.rawValue,
                                 message: "Unknown host method: \(method)", data: nil)
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

    private func uiToast(params: RPCValue?) -> RPCValue {
        let title = params?.objectValue?["title"]?.stringValue ?? "Halen"
        let body = params?.objectValue?["body"]?.stringValue ?? ""
        // Real UNUserNotification + overlay surfacing comes in a later milestone;
        // for now the log line is the visible artifact, which is enough to
        // prove the round-trip end-to-end.
        Log.info("toast: \(title): \(body)")
        return .object(["ok": true] as [String: Any?])
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
