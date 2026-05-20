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

    /// True between `start()` and the end of `terminate()`. Reader/stderr
    /// tasks keep looping while this is true so the polite-shutdown response
    /// has a chance to come back through the pump.
    private(set) var isRunning = false
    /// Set when `terminate()` begins so a concurrent caller doesn't start a
    /// second shutdown ladder while the first is mid-flight.
    private var shuttingDown = false

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
    ///
    /// Crucially, `isRunning` stays `true` across the polite phase so the
    /// reader continues to consume stdout — without this, the plugin's
    /// response to our `shutdown` request would never be processed and the
    /// `call` would always time out, defeating the polite path.
    func terminate() async {
        guard isRunning, !shuttingDown else { return }
        shuttingDown = true

        do {
            _ = try await call(method: "shutdown", params: nil, timeoutSeconds: 2)
            try? send(notification: "exit")
        } catch {
            Log.warn("PluginInstance[\(manifest.id)]: shutdown call failed (\(error.localizedDescription)) — escalating")
        }

        // Give the plugin 1 s to exit on its own after `exit`.
        let exitDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < exitDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        // The polite phase is done — flip `isRunning` so reader/stderr loops
        // wind down naturally on their next pipe-close iteration.
        isRunning = false

        if process.isRunning { process.terminate() }
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }

        // Detach the readabilityHandlers first so no further callbacks fire,
        // then cancel the AsyncStream consumers, then close the pipes.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        readerTask?.cancel()
        stderrTask?.cancel()
        // Closing stdin lets the plugin's stdin read() return 0 (EOF) cleanly
        // on the polite-shutdown path; closing our read ends releases them.
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        Log.info("PluginInstance[\(manifest.id)]: terminated")
    }

    /// Defensive cleanup if the instance is dropped without `terminate()`
    /// (test harness, future hot-reload, programming error). Foundation
    /// `Process` does not kill its child on dealloc, so without this the
    /// plugin process would outlive Halen.
    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Outgoing

    /// Issue a request to the plugin and `await` the response.
    ///
    /// Two correctness traps the previous implementation fell into and this
    /// one avoids:
    ///   * The pending continuation MUST be stored before the message is
    ///     written. A fast plugin can respond before the next MainActor hop
    ///     runs; if the slot isn't populated by then, `handleResponse`
    ///     silently drops the response and the call always times out.
    ///   * `withCheckedThrowingContinuation` is not cancellable, so a
    ///     "race a timeout" implementation has to actively `resume(throwing:)`
    ///     on timeout or the continuation leaks (Swift runtime prints a
    ///     "leaked" warning and the next late response goes nowhere).
    @discardableResult
    func call(method: String, params: RPCValue?, timeoutSeconds: TimeInterval = 30) async throws -> RPCValue {
        let id = nextId; nextId += 1

        // Schedule the timeout — runs concurrent with the call. On wake it
        // tries to remove the pending entry; if it's already gone (response
        // beat us to it) it's a no-op. If still there, it resumes with a
        // timeout error, ensuring no continuation ever leaks.
        let timeoutTask = Task { @MainActor [weak self, methodName = method] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self else { return }
            if let pendingCont = self.pending.removeValue(forKey: id) {
                pendingCont.resume(throwing: RPCErrorObject(
                    code: PluginRPC.ErrorCode.internalError.rawValue,
                    message: "Plugin \(methodName) timed out after \(Int(timeoutSeconds))s",
                    data: nil
                ))
            }
        }

        return try await withCheckedThrowingContinuation { cont in
            // Store first — `call()` and `handleResponse` both run on the
            // MainActor, so the response can never be processed between this
            // assignment and the `writeMessage` below.
            pending[id] = cont
            do {
                try writeMessage(RPCMessage(id: .number(id), method: method, params: params))
            } catch {
                // Pipe closed mid-write — clean up immediately.
                pending.removeValue(forKey: id)
                timeoutTask.cancel()
                cont.resume(throwing: error)
            }
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
        readerTask = installLineReader(on: stdoutPipe.fileHandleForReading) { [weak self] line in
            guard let self, self.isRunning else { return }
            self.handleIncomingLine(Data(line.utf8))
        }
    }

    private func startStderrForwarder() {
        let id = manifest.id
        stderrTask = installLineReader(on: stderrPipe.fileHandleForReading) { [weak self] line in
            guard self?.isRunning == true else { return }
            Log.info("plugin[\(id)] \(line)")
        }
    }

    /// Read `\n`-delimited lines from `handle` and hand each to `onLine` on the
    /// MainActor, in order.
    ///
    /// Uses `readabilityHandler` rather than `FileHandle.bytes.lines`:
    /// `AsyncBytes` delivered pipe data in laggy ~15-second batches, which
    /// delayed every plugin JSON-RPC round-trip by that much. The
    /// readabilityHandler fires as soon as the pipe has bytes; lines are
    /// funnelled through an `AsyncStream` so the MainActor consumer sees them
    /// promptly and in order.
    private func installLineReader(on handle: FileHandle,
                                   onLine: @escaping @MainActor (String) -> Void)
        -> Task<Void, Never> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        // `accumulator` is touched only by this handle's readabilityHandler,
        // which the OS fires serially — no locking needed.
        let accumulator = LineBuffer()
        handle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                // EOF — the plugin closed the pipe / exited.
                fileHandle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in accumulator.drainLines(appending: chunk) {
                continuation.yield(line)
            }
        }
        return Task { @MainActor in
            for await line in stream { onLine(line) }
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
        guard case .number(let id) = msg.id else {
            // We only ever send numeric ids; a string-id response is either a
            // plugin bug or a response to a request from a different transport.
            Log.warn("PluginInstance[\(manifest.id)]: response with non-numeric id — dropping")
            return
        }
        guard let cont = pending.removeValue(forKey: id) else {
            // Almost always a late response after our timeout already fired.
            Log.debug("PluginInstance[\(manifest.id)]: response for unknown id \(id) (late after timeout?)")
            return
        }
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

/// Accumulates raw pipe bytes and yields complete `\n`-terminated lines —
/// the carry-buffer a chunked reader needs (one `read` can split a line, or
/// carry several). Confined to a single FileHandle's `readabilityHandler`,
/// which the OS fires serially: `@unchecked Sendable` because that serial
/// contract — not a lock — is the synchronisation.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    /// Append `chunk`, then return every complete line it now yields (text
    /// only, the `\n` stripped). A partial trailing line stays buffered.
    func drainLines(appending chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<newline]
            if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }
}
