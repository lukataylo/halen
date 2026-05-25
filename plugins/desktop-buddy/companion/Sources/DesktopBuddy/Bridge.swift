import Foundation

/// NDJSON-over-stdio bridge to `plugin.py`. One JSON object per line.
/// Reads on a background queue, dispatches handlers on the main thread so
/// Cocoa / SwiftUI state mutations stay on the main actor.
final class Bridge {
    var onMessage: (([String: Any]) -> Void)?

    private let readQueue = DispatchQueue(label: "buddy.bridge.read")
    private let writeQueue = DispatchQueue(label: "buddy.bridge.write")
    private let stdin = FileHandle.standardInput
    private let stdout = FileHandle.standardOutput
    private var buffer = Data()

    func start() {
        readQueue.async { [weak self] in self?.readLoop() }
    }

    func send(_ payload: [String: Any]) {
        writeQueue.async { [stdout] in
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.fragmentsAllowed]) else {
                return
            }
            var line = data
            line.append(0x0A) // '\n'
            do {
                try stdout.write(contentsOf: line)
            } catch {
                FileHandle.standardError.write(Data("buddy/companion: stdout write failed: \(error)\n".utf8))
            }
        }
    }

    func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func readLoop() {
        // Blocking read until EOF; plugin.py closes stdin on shutdown.
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            drainLines()
        }
        DispatchQueue.main.async {
            // Parent closed the pipe — exit cleanly so we don't linger.
            NSApplication.shared.terminate(nil)
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineRange = buffer.startIndex..<newline
            let line = buffer.subdata(in: lineRange)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.isEmpty { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                log("buddy/companion: ignored non-object JSON line")
                continue
            }
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(obj)
            }
        }
    }
}
