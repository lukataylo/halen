import Foundation
import Network
import AppKit
import ApplicationServices
import Observation

/// Local WebSocket server that lets non-process clients — browser extensions
/// today, eventually VS Code / Slack extension / iOS companion — speak the
/// same event-and-RPC protocol as out-of-process plugins.
///
/// Bound to `127.0.0.1` only: no external interfaces, no auth needed in v0
/// because the loopback constraint plus single-user macOS is the trust
/// boundary. (A future iteration adds a handshake token written to disk and
/// passed by the client on connect.)
///
/// Wire format: NDJSON-shaped JSON-RPC 2.0 messages — same `RPCMessage` and
/// `RPCValue` types the stdio plugin host uses, just delivered as WebSocket
/// text frames instead of stdout lines.
@MainActor
@Observable
final class WebSocketBridge {
    /// Pinned default port. Browser-extension code constants must match.
    /// `nonisolated` so default-arg initialisers (e.g. `init(services:port:)`)
    /// can read it from outside the MainActor.
    nonisolated static let defaultPort: UInt16 = 50765

    /// UserDefaults key controlling whether the bridge is started at launch.
    /// Default ON — installed clients (browser extension, future companions)
    /// can't function without it, and binding to loopback-only keeps the
    /// trust boundary tight.
    nonisolated static let enabledKey = "halen.websocketBridge.enabled"

    nonisolated static var isEnabledInDefaults: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let services: HalenServices
    private let bridge: HostBridge
    private let port: UInt16

    private var listener: NWListener?
    /// Observable-visible state — SettingsView reads `isListening` and
    /// `clientCount` for the live status card.
    private(set) var isListening = false
    private(set) var clientCount = 0

    private var clients: [Client] = []
    private var subscriptionTask: Task<Void, Never>?

    /// Connection wrapper. Keeps the `NWConnection` alive (without one we'd
    /// rely on the listener's strong ref) and lets us tag log lines with a
    /// stable per-client id.
    private final class Client: Identifiable {
        let id = UUID()
        let connection: NWConnection
        /// `nil` until the client has sent a valid `subscribe` notification.
        /// Unauthenticated clients can connect (so the popup's ping-and-close
        /// liveness check works) but get no events and can't inject any.
        var subscribedTopics: Set<String>?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(services: HalenServices, port: UInt16 = WebSocketBridge.defaultPort) {
        self.services = services
        self.bridge = HostBridge(services: services)
        self.port = port
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try makeListener()
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    Log.warn("WebSocketBridge: listener failed: \(err)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.isListening = true
            Log.info("WebSocketBridge: listening on 127.0.0.1:\(port)")
            startEventForwarder()
        } catch {
            Log.warn("WebSocketBridge: failed to bind 127.0.0.1:\(port) — \(error.localizedDescription)")
        }
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        for client in clients { client.connection.cancel() }
        clients.removeAll()
        clientCount = 0
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func makeListener() throws -> NWListener {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Filters incoming connections to loopback interfaces. The underlying
        // socket still binds to all-interfaces (Network.framework limitation),
        // but accepts only from 127.0.0.1 — see class doc comment.
        params.requiredInterfaceType = .loopback
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw WebSocketBridgeError.invalidPort(port)
        }
        return try NWListener(using: params, on: nwPort)
    }

    // MARK: - Per-client

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients.append(client)
        clientCount = clients.count
        Log.info("WebSocketBridge: client \(client.id.uuidString.prefix(8)) connected (\(clients.count) total)")

        // Capture only the UUID (Sendable) — looking the client up by id in
        // the handler avoids the Swift 6 warning about capturing the non-
        // Sendable Client class into the @Sendable state-update closure.
        let clientID = client.id
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    if let c = self.clients.first(where: { $0.id == clientID }) {
                        self.removeClient(c)
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: client)
    }

    /// Recursive receive — each completion handler re-arms itself until the
    /// connection closes or errors. `Network.framework` doesn't expose an
    /// async/await receive on connections, so the callback chain is the
    /// idiomatic shape. Captures the client *id* (Sendable) and re-resolves
    /// inside the MainActor hop to avoid the @Sendable-closure warning.
    private func receive(on client: Client) {
        let clientID = client.id
        client.connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self,
                      let resolved = self.clients.first(where: { $0.id == clientID })
                else { return }
                if let data, !data.isEmpty {
                    self.handleIncoming(data: data, from: resolved)
                }
                if error != nil {
                    self.removeClient(resolved)
                } else {
                    self.receive(on: resolved)
                }
            }
        }
    }

    private func removeClient(_ client: Client) {
        client.connection.cancel()
        clients.removeAll { $0.id == client.id }
        clientCount = clients.count
        Log.info("WebSocketBridge: client \(client.id.uuidString.prefix(8)) gone (\(clients.count) left)")
    }

    // MARK: - Event forwarding (host → clients)

    private func startEventForwarder() {
        subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.services.eventBus.subscribe() {
                self.broadcast(event)
            }
        }
    }

    private func broadcast(_ event: Event) {
        guard !clients.isEmpty,
              let (topic, payload) = event.toBroadcast() else { return }
        // Filter to clients that authenticated AND subscribed to this topic.
        // Unauthenticated or wrong-topic clients receive nothing — that's the
        // whole point of the subscribe-with-token handshake.
        let targets = clients.filter { $0.subscribedTopics?.contains(topic) == true }
        guard !targets.isEmpty else { return }
        let msg = RPCMessage(method: "event/\(topic)",
                             params: .object(["topic": .string(topic), "payload": payload]))
        send(msg, to: targets)
    }

    private func send(_ msg: RPCMessage, to targets: [Client]) {
        guard let data = try? JSONEncoder().encode(msg) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "halen.ws", metadata: [metadata])
        for client in targets {
            client.connection.send(content: data, contentContext: context,
                                   isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Incoming (clients → host)

    private func handleIncoming(data: Data, from client: Client) {
        guard let msg = try? JSONDecoder().decode(RPCMessage.self, from: data) else {
            Log.warn("WebSocketBridge: dropped malformed message from \(client.id.uuidString.prefix(8))")
            return
        }
        if msg.isRequest {
            Task { @MainActor in await self.handleRequest(msg, from: client) }
        } else if msg.isNotification {
            handleNotification(msg, from: client)
        }
        // Responses to our outbound requests would land here — we don't
        // currently make any, but the dispatcher is ready when we do.
    }

    private func handleNotification(_ msg: RPCMessage, from client: Client) {
        guard let method = msg.method else { return }

        // Subscription handshake: client posts `{token, topics: [...]}`.
        // Without it, the client is connected but ignored for everything
        // below — the auth gate that loopback-only binding doesn't give us.
        if method == "subscribe" {
            handleSubscribe(msg, from: client)
            return
        }

        // Every method below requires an authenticated subscription. Unauth'd
        // clients can liveness-ping (popup) but can neither receive events
        // nor inject them into the EventBus.
        guard client.subscribedTopics != nil else {
            Log.debug("WebSocketBridge: ignored \(method) from unauthenticated client \(client.id.uuidString.prefix(8))")
            return
        }

        // Clients can inject events (the browser extension's main use case).
        // Publishing onto the EventBus means every in-process plugin reacts
        // uniformly, with no per-client wiring.
        guard method.hasPrefix("event/"),
              let params = msg.params?.objectValue,
              let topic = params["topic"]?.stringValue,
              let payloadObj = params["payload"]?.objectValue
        else { return }

        switch topic {
        case "text.pause":
            guard let text = payloadObj["text"]?.stringValue else { return }
            let bundle = payloadObj["appBundleId"]?.stringValue ?? "ext.unknown"
            let name = payloadObj["appName"]?.stringValue ?? "Browser tab"
            let offset = payloadObj["caretOffset"]?.intValue ?? text.utf16.count
            services.eventBus.publish(.textPaused(.init(
                appBundleId: bundle, appName: name,
                text: text, caretOffset: offset, timestamp: Date()
            )))
        default:
            break
        }
    }

    /// Validate the client's `subscribe` notification against the persisted
    /// token; on success, record the requested topics so `broadcast(...)`
    /// fan-out can filter on them.
    ///
    /// Shape: `subscribe { token: "...", topics: ["text.pause", "app.focused"] }`.
    /// Topics not in the bridge's set of emitted topics are dropped silently.
    private func handleSubscribe(_ msg: RPCMessage, from client: Client) {
        guard let params = msg.params?.objectValue,
              let providedToken = params["token"]?.stringValue,
              let topicsAny = params["topics"]?.arrayValue
        else {
            Log.warn("WebSocketBridge: bad subscribe payload from \(client.id.uuidString.prefix(8))")
            return
        }
        guard let expected = BridgeTokenStore.tokenOrCreate(),
              providedToken == expected else {
            Log.warn("WebSocketBridge: rejected subscribe from \(client.id.uuidString.prefix(8)) — token mismatch")
            return
        }
        let valid: Set<String> = ["text.pause", "caret.moved", "app.focused"]
        let topics = Set(topicsAny.compactMap { $0.stringValue }).intersection(valid)
        client.subscribedTopics = topics
        let topicList = topics.sorted().joined(separator: ", ")
        Log.info("WebSocketBridge: \(client.id.uuidString.prefix(8)) subscribed to [\(topicList)]")
    }

    private func handleRequest(_ msg: RPCMessage, from client: Client) async {
        guard let id = msg.id, let method = msg.method else { return }
        do {
            // Single source of truth for every host method, shared with
            // PluginHost. The WS transport now gets the full surface for
            // free (ax/replaceRange, ui/toast — previously missing here).
            let result = try await bridge.dispatch(method: method, params: msg.params)
            send(RPCMessage(id: id, result: result), to: [client])
        } catch let error as RPCErrorObject {
            send(RPCMessage(id: id, error: error), to: [client])
        } catch {
            send(RPCMessage(id: id, error: RPCErrorObject(
                code: PluginRPC.ErrorCode.internalError.rawValue,
                message: error.localizedDescription, data: nil
            )), to: [client])
        }
    }
}

enum WebSocketBridgeError: Error, LocalizedError {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Halen WebSocket bridge: invalid port \(port)"
        }
    }
}
