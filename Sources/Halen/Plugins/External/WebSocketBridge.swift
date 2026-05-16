import Foundation
import Network
import AppKit
import ApplicationServices

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
final class WebSocketBridge {
    /// Pinned default port. Browser-extension code constants must match.
    /// `nonisolated` so default-arg initialisers (e.g. `init(services:port:)`)
    /// can read it from outside the MainActor.
    nonisolated static let defaultPort: UInt16 = 50765

    private let services: HalenServices
    private let bridge: HostBridge
    private let port: UInt16

    private var listener: NWListener?
    private var clients: [Client] = []
    private var subscriptionTask: Task<Void, Never>?

    /// Connection wrapper. Keeps the `NWConnection` alive (without one we'd
    /// rely on the listener's strong ref) and lets us tag log lines with a
    /// stable per-client id.
    private final class Client: Identifiable {
        let id = UUID()
        let connection: NWConnection
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
        listener?.cancel()
        listener = nil
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
        let msg = RPCMessage(method: "event/\(topic)",
                             params: .object(["topic": .string(topic), "payload": payload]))
        send(msg, to: clients)
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
            handleNotification(msg)
        }
        // Responses to our outbound requests would land here — we don't
        // currently make any, but the dispatcher is ready when we do.
    }

    private func handleNotification(_ msg: RPCMessage) {
        // Clients can inject events. The big use case: browser extensions
        // reporting DOM-text.pause events that AX can't see (Slack web,
        // Discord web, Google Docs, etc.). Publishing onto the EventBus
        // means every in-process plugin (SnippetExpander, TypoFixer,
        // SentimentGuard) reacts uniformly, with no per-client wiring.
        guard let method = msg.method,
              method.hasPrefix("event/"),
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
