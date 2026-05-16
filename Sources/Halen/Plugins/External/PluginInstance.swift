import Foundation

/// One running plugin process and the JSON-RPC pump for it. Owns:
///
///  * the `Process` (spawned with stdio piped)
///  * a writer that serializes outgoing messages to the plugin's stdin
///  * a reader Task that pulls NDJSON lines off the plugin's stdout and
///    routes them as requests (call into `handler`) or responses (resume
///    the matching pending continuation)
///  * the plugin's stderr → `Log` forwarder
///
/// One instance per plugin process. Crashes don't take down other plugins
/// (per-process isolation) and the host can choose to restart.
@MainActor
final class PluginInstance {
    let manifest: PluginManifest
    let pluginDir: URL

    /// Caller-supplied handler for plugin→host requests. Returning a value or
    /// throwing an `RPCErrorObject` lets the bridge map a method to either a
    /// success result or a JSON-RPC error.
    typealias RequestHandler = @MainActor (String, RPCValue?) async throws -> RPCValue

    private let handler: RequestHandler

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<RPCValue, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    /// True between `start()` and `terminate()`. Reader/stderr tasks loop only
    /// while running so cancellation winds them down cleanly.
    private(set) var isRunning = false

    init(manifest: PluginManifest, pluginDir: URL, handler: @escaping RequestHandler) {
        self.manifest = manifest
        self.pluginDir = pluginDir
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Spawn the plugin process and run the lifecycle handshake. Returns once
    /// `notifications/initialized` has been sent; the plugin is then live and
    /// ready to receive events.
    func start() async throws {
        guard !isRunning else { return }

        process.executableURL = manifest.resolvedExecutable(in: pluginDir)
        process.arguments = manifest.args
        process.currentDirectoryURL = pluginDir
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Merge host env with manifest-declared overrides. Plugin authors get
        // PATH etc. for free; they can pin a venv via `env.PATH = ...`.
        var env = ProcessInfo.processInfo.environment
        for (k, v) in manifest.env ?? [:] { env[k] = v }
        env["HALEN_PLUGIN_DIR"] = pluginDir.path   // plugins find their resources here
        process.environment = env

        try process.run()
        isRunning = true
        startReader()
        startStderrForwarder()
        Log.info("PluginInstance[\(manifest.id)]: spawned pid=\(process.processIdentifier)")

        // Handshake: initialize → wait for response → send initialized.
        let initParams = RPCValue.object([
            "protocolVersion": manifest.halenApiVersion,
            "hostInfo": [
                "name": "Halen",
                "version": "0.1.0"
            ],
            "capabilities": [
                "inference": ["streaming": false,
                              "tiers": ["small", "medium", "large"]],
                "ax": ["read": true, "write": true],
                "ui": ["toast": true]
            ]
        ] as [String: Any?])
        _ = try await call(method: "initialize", params: initParams)
        try send(notification: "notifications/initialized")
    }

    /// Polite shutdown: `shutdown` request → `exit` notification → wait briefly
    /// → SIGTERM → SIGKILL. MCP's escalation ladder, lifted into the host so
    /// well-behaved plugins flush state cleanly and broken ones still die.
    func terminate() async {
        guard isRunning else { return }
        isRunning = false
        do {
            _ = try await call(method: "shutdown", params: nil, timeoutSeconds: 2)
            try send(notification: "exit")
        } catch {
            // Plugin already in a bad state — skip the polite path.
        }
        // Give it 1 s to exit on its own, then escalate.
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }

        readerTask?.cancel()
        stderrTask?.cancel()
        try? stdinPipe.fileHandleForWriting.close()
        Log.info("PluginInstance[\(manifest.id)]: terminated")
    }

    // MARK: - Outgoing

    /// Issue a request to the plugin and `await` the response. `timeoutSeconds`
    /// gives a per-call ceiling so a hung plugin doesn't pin the caller.
    @discardableResult
    func call(method: String, params: RPCValue?, timeoutSeconds: TimeInterval = 30) async throws -> RPCValue {
        let id = nextId; nextId += 1
        let msg = RPCMessage(id: .number(id), method: method, params: params)
        try writeMessage(msg)

        return try await withThrowingTaskGroup(of: RPCValue.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { cont in
                    // `pending` is MainActor-isolated; capture into the parent
                    // task continuation via a hop. Stored under `id` so the
                    // reader can find and resume on response.
                    Task { @MainActor in self?.pending[id] = cont }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw RPCErrorObject(
                    code: PluginRPC.ErrorCode.internalError.rawValue,
                    message: "Plugin \(method) timed out after \(Int(timeoutSeconds))s",
                    data: nil
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            pending.removeValue(forKey: id)
            return result
        }
    }

    /// Fire-and-forget notification. Plugins consume these via their own
    /// message dispatch; the host doesn't await a response.
    func send(notification method: String, params: RPCValue? = nil) throws {
        let msg = RPCMessage(method: method, params: params)
        try writeMessage(msg)
    }

    /// Same as `send(notification:)` but for event topics. Filters by the
    /// manifest's `events` allowlist so plugins only get what they asked for.
    func deliver(event topic: String, payload: RPCValue) {
        guard manifest.events?.contains(topic) ?? false else { return }
        let params = RPCValue.object([
            "topic": .string(topic),
            "payload": payload
        ])
        try? send(notification: "event/\(topic)", params: params)
    }

    // MARK: - Internals

    private func writeMessage(_ msg: RPCMessage) throws {
        var data = try JSONEncoder().encode(msg)
        // NDJSON framing: one message per line, terminator is a single \n.
        // JSON encoder doesn't emit raw newlines inside strings (escaped to
        // \n) so the line boundary is unambiguous.
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func startReader() {
        readerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let handle = self.stdoutPipe.fileHandleForReading
            do {
                // NDJSON: one message per line — `.lines` is the right primitive,
                // no carry-buffer needed.
                for try await line in handle.bytes.lines where self.isRunning {
                    self.handleIncomingLine(Data(line.utf8))
                }
            } catch {
                if self.isRunning {
                    Log.warn("PluginInstance[\(self.manifest.id)]: stdout reader error: \(error)")
                }
            }
        }
    }

    private func startStderrForwarder() {
        stderrTask = Task { @MainActor [weak self, id = manifest.id] in
            guard let self else { return }
            let handle = self.stderrPipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines where self.isRunning {
                    Log.info("plugin[\(id)] \(line)")
                }
            } catch {
                // Pipe closed on terminate — normal end-of-life, don't log.
            }
        }
    }

    private func handleIncomingLine(_ data: Data) {
        let decoded: RPCMessage
        do {
            decoded = try JSONDecoder().decode(RPCMessage.self, from: data)
        } catch {
            Log.warn("PluginInstance[\(manifest.id)]: malformed JSON-RPC line: \(error)")
            return
        }
        if decoded.isResponse {
            handleResponse(decoded)
        } else if decoded.isRequest {
            Task { @MainActor in await self.handleRequest(decoded) }
        } else if decoded.isNotification {
            // Notifications from the plugin (e.g. `$/log`) — discard for now,
            // stderr is the main log channel.
        }
    }

    private func handleResponse(_ msg: RPCMessage) {
        guard case .number(let id) = msg.id, let cont = pending.removeValue(forKey: id) else { return }
        if let error = msg.error {
            cont.resume(throwing: error)
        } else {
            cont.resume(returning: msg.result ?? .null)
        }
    }

    private func handleRequest(_ msg: RPCMessage) async {
        guard let method = msg.method, let id = msg.id else { return }
        do {
            let result = try await handler(method, msg.params)
            try writeMessage(RPCMessage(id: id, result: result))
        } catch let error as RPCErrorObject {
            try? writeMessage(RPCMessage(id: id, error: error))
        } catch {
            try? writeMessage(RPCMessage(id: id, error: RPCErrorObject(
                code: PluginRPC.ErrorCode.internalError.rawValue,
                message: error.localizedDescription,
                data: nil
            )))
        }
    }
}
