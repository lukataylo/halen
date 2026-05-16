import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer self-test: `HALEN_SELFTEST=1 ./halen` exercises the bundled
        // llama.cpp backend directly and exits, with no Accessibility dependency.
        if ProcessInfo.processInfo.environment["HALEN_SELFTEST"] != nil {
            Task { @MainActor in
                await SelfTest.run()
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }

    /// Re-probe inference backends whenever Halen returns to the foreground.
    /// Catches the common "user went to System Settings → Apple Intelligence,
    /// toggled it on, came back to Halen" flow without making the user wait
    /// for the Settings panel's 30-second poll (or hunt for the Refresh
    /// button). Ditto for "user started Ollama in another terminal".
    func applicationDidBecomeActive(_ notification: Notification) {
        let router = coordinator.inference
        Task { await router.refreshAvailability() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // `applicationShouldTerminate` (below) is the one that actually waits
        // on the async cleanup; this hook fires after we've already replied
        // `.terminateNow`, so all the polite plumbing has finished.
        coordinator.stop()
    }

    /// Defer termination until the async plugin-host + WS-bridge shutdown
    /// actually finishes. Without this, `applicationWillTerminate` returns
    /// synchronously and the process dies before the `Task { await
    /// pluginHost.stop() }` ladder (shutdown → exit → SIGTERM → SIGKILL) can
    /// complete — leaving plugin child processes orphaned and connected WS
    /// clients with a half-closed socket.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Already shutting down — let it through.
        if coordinator.isShuttingDown { return .terminateNow }

        Task { @MainActor in
            await coordinator.shutdown()
            // Hard cap of ~3 s — past that the user's "Quit" feels stuck.
            // `coordinator.shutdown()` itself respects its own deadlines, so
            // this is just a defensive backstop.
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Minimal end-to-end check for the bundled inference path. Not part of the
/// shipping UI — triggered only via the `HALEN_SELFTEST` env var.
enum SelfTest {
    static func run() async {
        Log.info("SelfTest: starting")
        let backend = LlamaCppBackend()
        let availability = await backend.availability()
        Log.info("SelfTest: bundled-llama availability = \(availability)")
        guard case .available = availability else {
            Log.error("SelfTest: bundled model unavailable — aborting")
            return
        }
        let request = InferenceRequest(
            prompt: "Reply with exactly one word: hello",
            tier: .small,
            maxTokens: 16,
            temperature: 0.1,
            taskKind: .classification
        )
        do {
            let response = try await backend.complete(request)
            Log.info("SelfTest: OK — modelId=\(response.modelId) latencyMs=\(response.latencyMs) text=\"\(response.text)\"")
        } catch {
            Log.error("SelfTest: complete() failed — \(error)")
        }
    }
}
