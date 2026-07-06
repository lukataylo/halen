import Foundation
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "socket")

/// Unix domain socket server for hook IPC.
/// Listens on ~/.notchbar/notchbar.sock for connections from the hook script.
/// Each connection: read event JSON line, decide, write response JSON line, close.
class SocketServer {
    let socketPath: String
    private var listenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.notchbar.socket", qos: .userInteractive)
    private var onEvent: ((ClaudeCodeEvent, String, @escaping (String) -> Void) -> Void)?

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notchbar")
        socketPath = base.appendingPathComponent("notchbar.sock").path
    }

    /// Callback to cancel a pending response (called on socket timeout).
    /// Set by the bridge so it can clean up orphaned approval timers.
    var onTimeout: ((ClaudeCodeEvent) -> Void)?

    /// Start listening. `handler` is called for each event with (event, hookType, respond).
    /// Call `respond(jsonString)` to send the response back to the hook script.
    /// Handler is called on a background thread — dispatch to main for UI work.
    func start(handler: @escaping (ClaudeCodeEvent, String, @escaping (String) -> Void) -> Void) {
        onEvent = handler

        // Clean up stale socket from previous crash
        // Try connecting first — if it succeeds, another instance is running
        let testFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if testFD >= 0 {
            var testAddr = sockaddr_un()
            testAddr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &testAddr.sun_path) { ptr in
                let bytes = socketPath.utf8CString
                ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                    for i in 0..<bytes.count { dest[i] = bytes[i] }
                }
            }
            let connected = withUnsafePointer(to: &testAddr, { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(testFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }) == 0
            close(testFD)
            if connected {
                log.warning("Another NotchBar instance is already listening on the socket")
                return
            }
        }
        unlink(socketPath)

        // Ensure socket directory exists
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)

        // Create socket
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            log.error("Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            log.error("Socket path too long: \(self.socketPath)")
            close(listenFD); listenFD = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, addrLen) }
        }) == 0 else {
            log.error("Failed to bind socket: \(String(cString: strerror(errno)))")
            close(listenFD); listenFD = -1
            return
        }

        // Listen
        guard listen(listenFD, 16) == 0 else {
            log.error("Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(listenFD); listenFD = -1
            return
        }

        // Set socket permissions (owner only)
        chmod(socketPath, 0o700)

        running = true
        log.info("Socket server listening at \(self.socketPath)")

        // Accept loop on background thread
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &clientLen) }
            }
            guard clientFD >= 0 else {
                if running { log.error("Accept failed: \(String(cString: strerror(errno)))") }
                continue
            }

            // Handle each connection on a concurrent thread for parallelism
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    private func handleConnection(fd: Int32) {
        defer { close(fd) }

        // Set read timeout (10 seconds) to avoid hanging on bad clients
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read all data until EOF or newline
        var buffer = Data()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { chunk.deallocate() }

        while true {
            let n = read(fd, chunk, 65536)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            // Check for newline delimiter — hook sends one JSON object per line
            if buffer.contains(0x0A) { break }
        }

        guard !buffer.isEmpty else { return }

        // Parse the JSON
        guard let event = try? JSONDecoder().decode(ClaudeCodeEvent.self, from: buffer) else {
            log.error("Failed to decode event from socket — rejecting malformed request")
            let response = "{\"error\":\"malformed request\"}\n"
            _ = response.utf8CString.withUnsafeBufferPointer { ptr in
                write(fd, ptr.baseAddress, response.utf8.count)
            }
            return
        }

        let hookType = event.hookType ?? event.hookEventName?.lowercased() ?? ""

        // For post-tool-use, process the event and send a short ack so the client closes cleanly
        if hookType != "pre-tool-use" && hookType != "pretooluse" {
            onEvent?(event, hookType, { _ in })
            let ack = "{\"ok\":true}\n"
            _ = ack.withCString { ptr in write(fd, ptr, ack.utf8.count) }
            return
        }

        // For pre-tool-use: call handler and wait for response
        let semaphore = DispatchSemaphore(value: 0)
        var responseJSON = "{\"decision\":\"approve\"}"
        var responded = false
        let lock = NSLock()

        onEvent?(event, hookType) { response in
            lock.lock()
            guard !responded else { lock.unlock(); return }
            responded = true
            responseJSON = response
            lock.unlock()
            semaphore.signal()
        }

        let timeoutMinutes = AppSettings.shared.approvalTimeoutMinutes
        if timeoutMinutes <= 0 {
            semaphore.wait()
        } else {
            let timeout = DispatchTime.now() + .seconds(timeoutMinutes * 60)
            if semaphore.wait(timeout: timeout) == .timedOut {
                lock.lock()
                if !responded {
                    responded = true
                    responseJSON = "{\"decision\":\"approve\"}"
                    lock.unlock()
                    log.warning("Approval timed out after \(timeoutMinutes)min, auto-approving")
                    onTimeout?(event)
                } else {
                    lock.unlock()
                    // Callback beat us — responseJSON already set
                }
            }
        }

        // Send response (safe — either callback or timeout wrote it under lock)
        lock.lock()
        let line = responseJSON + "\n"
        lock.unlock()
        _ = line.withCString { ptr in
            write(fd, ptr, line.utf8.count)
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
        log.info("Socket server stopped")
    }
}
