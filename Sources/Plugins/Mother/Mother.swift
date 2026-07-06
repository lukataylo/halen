import AppKit
import Foundation
import HalenPluginAPI
import SwiftUI

/// Mother — a loving but firm discipline enforcer, ported in-process from the
/// out-of-process Python plugin. She keeps you off the apps and websites you
/// told her to keep you off, and she does not negotiate during your focus
/// hours. Everything is local: no network, no accounts, no telemetry.
///
/// She watches two surfaces —
///
///   A. blocklisted **apps**  — from the host's `app.focused` events
///   B. blocklisted **sites** — the active browser tab, read over AppleScript
///
/// — and enforces them with escalating, deterministic consequences:
///
///   * soft     — a stern notification, logged. Nothing is closed.
///   * hardcore — inside focus hours she quits the app / closes the tab, no
///                override. Outside focus hours she confronts first and lets
///                you bail to a real task, but quits if you ignore her.
///   * lockdown — always immediate. No prompt, no override, ever.
///
/// Toasts and modal prompts go through the host (`context.ui`). Quitting an
/// app is plain AppKit (`NSRunningApplication.terminate()` — a graceful quit,
/// the app can still prompt to save). Reading/closing a browser tab is
/// Mother's own `osascript` subprocess, declared via the `automation`
/// capability; macOS shows its standard Automation consent per browser.
///
/// Config + ledger live in `context.storage.directory` (the host maps it to
/// `~/Library/Application Support/Halen/com.halen.mother/` — the same
/// directory the Python plugin used) as `config.json` / `state.json`, with
/// the schemas unchanged, so an existing user's rulebook and history carry
/// straight over.
@MainActor
public final class Mother: HalenPlugin {
    public static let pluginManifest = PluginManifest(
        id: "com.halen.mother", name: "Mother",
        summary: "A loving but firm app blocker for your focus hours.",
        version: "0.4.0",
        events: ["app.focused"],
        capabilities: [.observeApps, .notifications, .popoverUI, .automation],
        icon: "figure.stand.line.dotted.figure.stand", category: .focus)

    public var manifest: PluginManifest { Self.pluginManifest }

    private let context: PluginContext
    let store: MotherConfigStore

    // ── Long-lived tasks (cancelled in stop()) ─────────────────────────
    private var eventTask: Task<Void, Never>?
    private var sitePollTask: Task<Void, Never>?
    private var configWatchTask: Task<Void, Never>?

    // ── App enforcement state ──────────────────────────────────────────
    /// One pending grace check per app (port of `_app_timers`).
    private var graceTasks: [String: Task<Void, Never>] = [:]
    /// Bundle ids currently being confronted, to avoid stacking.
    private var appBusy: Set<String> = []
    /// bundleId → epoch the override pass expires.
    private var appPasses: [String: Date] = [:]
    /// Only one confrontation prompt on screen at a time. The host presenter
    /// is single-slot: opening a second prompt dismisses the first and
    /// resolves it nil — which on the app path means an *unintended quit*.
    /// If another prompt is already up, skip leniently this cycle.
    private var confrontInProgress = false

    // ── Site enforcement state ─────────────────────────────────────────
    /// The (AppleScript name, front-tab phrase) of the frontmost browser, or
    /// nil when a non-browser is front. Drives the poller.
    private var frontBrowser: (appName: String, tabPhrase: String)?
    private var siteBusy: Set<String> = []
    /// host → epoch the override pass expires.
    private var sitePasses: [String: Date] = [:]
    /// host → monotonic instant Mother last acted on it. A pinned or
    /// session-restored blocked tab would otherwise be closed *and* toasted
    /// every poll forever; act on a given host at most once per cooldown.
    private var siteLastEnforced: [String: ContinuousClock.Instant] = [:]
    private static let siteEnforceCooldown: Duration = .seconds(30)

    /// Browsers Mother can read the front tab of, by bundle id. Each entry is
    /// the AppleScript application name plus the dialect for "the front tab".
    /// Safari says "current tab"; the Chromium family and Arc say "active tab".
    /// Firefox has no reliable AppleScript tab API, so it isn't here.
    private static let browsers: [String: (appName: String, tabPhrase: String)] = [
        "com.apple.Safari": ("Safari", "current tab"),
        "com.apple.SafariTechnologyPreview": ("Safari Technology Preview", "current tab"),
        "com.google.Chrome": ("Google Chrome", "active tab"),
        "com.google.Chrome.canary": ("Google Chrome Canary", "active tab"),
        "com.brave.Browser": ("Brave Browser", "active tab"),
        "com.microsoft.edgemac": ("Microsoft Edge", "active tab"),
        "com.vivaldi.Vivaldi": ("Vivaldi", "active tab"),
        "company.thebrowser.Browser": ("Arc", "active tab"),
    ]

    public init(context: PluginContext) {
        self.context = context
        self.store = MotherConfigStore(directory: context.storage.directory)
    }

    // MARK: - Lifecycle

    public func start() {
        store.reloadConfigIfChanged()
        Log.info("Mother: online. Discipline is in session.")

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.context.events.subscribe() {
                if Task.isCancelled { break }
                if case .appFocused(let payload) = event {
                    self.handleAppFocused(bundleId: payload.appBundleId)
                }
            }
        }
        sitePollTask = Task { [weak self] in
            await self?.sitePollLoop()
        }
        // Hot-reload config.json whenever its mtime moves (checked every 5 s),
        // so editing the JSON by hand still works exactly like it did.
        configWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                self?.store.reloadConfigIfChanged()
            }
        }
    }

    public func stop() {
        eventTask?.cancel(); eventTask = nil
        sitePollTask?.cancel(); sitePollTask = nil
        configWatchTask?.cancel(); configWatchTask = nil
        for task in graceTasks.values { task.cancel() }
        graceTasks.removeAll()
        appBusy.removeAll()
        siteBusy.removeAll()
        frontBrowser = nil
        confrontInProgress = false
        Log.info("Mother: stopped.")
    }

    public func makeDetailView() -> AnyView {
        AnyView(MotherDetailView(store: store))
    }

    // MARK: - Mode

    /// Port of `current_mode()`, with the same fail-safe logging for an
    /// unrecognized enforcement string.
    private func currentMode() -> MotherMode {
        if !store.config.enforcementIsRecognized {
            Log.warn("Mother: unknown enforcement '\(store.config.enforcement)'; falling back to 'warn'")
        }
        return store.config.effectiveMode()
    }

    // MARK: - App enforcement

    private func handleAppFocused(bundleId: String) {
        // Drive the browser poller: set when a browser takes focus, idle otherwise.
        frontBrowser = Self.browsers[bundleId]

        guard let name = blockedAppName(bundleId) else { return }
        guard !hasPass(&appPasses, key: bundleId) else { return }
        guard !appBusy.contains(bundleId), graceTasks[bundleId] == nil else { return }

        // A short grace forgives an accidental ⌘-Tab; it is not a loophole.
        let grace = max(0, Int(store.config.graceSeconds))
        graceTasks[bundleId] = Task { [weak self] in
            if grace > 0 { try? await Task.sleep(for: .seconds(grace)) }
            guard !Task.isCancelled else { return }
            await self?.graceElapsed(bundleId: bundleId, name: name)
        }
    }

    private func graceElapsed(bundleId: String, name: String) async {
        graceTasks[bundleId] = nil
        // Only act if the blocked app is *still* frontmost — verified live,
        // not from a possibly-stale focus event. ⌘-Tabbing away within the
        // grace is forgiven.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else { return }
        guard !hasPass(&appPasses, key: bundleId) else { return }
        guard !appBusy.contains(bundleId) else { return }
        appBusy.insert(bundleId)
        defer { appBusy.remove(bundleId) }
        await enforceApp(bundleId: bundleId, name: name)
    }

    private func enforceApp(bundleId: String, name: String) async {
        let mode = currentMode()
        switch mode {
        case .off:
            return

        case .warn:
            toast("\(name) is on your blocklist",
                  "Mother sees you. Logged — but she's letting it slide this time.")
            store.record(kind: "app", target: name, action: "warned")

        case .enforceNoOverride:
            quitApp(bundleId: bundleId)
            store.record(kind: "app", target: name, action: "quit")
            toast("Mother closed \(name)",
                  "It's on your blocklist and you're in focus hours. Back to work.")

        case .enforceOverride:
            // Confront, give one friction-laden way out. Serialized so a
            // concurrent site confrontation can't dismiss this prompt out
            // from under the user (nil here = an unintended quit).
            guard !confrontInProgress else {
                Log.info("Mother: a confrontation is already on screen; skipping \(bundleId) this cycle")
                return
            }
            confrontInProgress = true
            defer { confrontInProgress = false }

            // Guard against a non-positive / NaN misconfig: the popup's
            // lifetime must stay positive.
            var confront = store.config.confrontTimeoutSeconds
            if !(confront > 0) { confront = 45 }

            let action = await prompt(
                title: "Mother",
                body: "\(name) is on your blocklist. You're outside focus hours, so "
                    + "Mother will let you decide — once.",
                actions: ["Close it", "Override (logged)"],
                timeoutSeconds: confront)

            if action == "Override (logged)", await confirmOverride(target: name) {
                grantPass(&appPasses, key: bundleId)
                store.record(kind: "app", target: name, action: "override")
                toast("Override granted",
                      "\(overrideMinutesText) minutes on \(name). Mother wrote it down.")
                return
            }
            // "Close it", dismissed, timed out, or override declined → enforce.
            quitApp(bundleId: bundleId)
            store.record(kind: "app", target: name, action: "quit")
        }
    }

    /// Second gate. Override is never one click — that's the discipline.
    private func confirmOverride(target: String) async -> Bool {
        let action = await prompt(
            title: "Mother is watching",
            body: "This override is recorded against you. Still want "
                + "\(overrideMinutesText) minutes on \(target)?",
            actions: ["No — close it", "Yes, I accept the cost"],
            timeoutSeconds: 35)
        return action == "Yes, I accept the cost"
    }

    /// Ask the app to quit gracefully — `terminate()` sends a normal quit
    /// event, so an app with unsaved work can still prompt to save.
    private func quitApp(bundleId: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !running.isEmpty else {
            Log.warn("Mother: asked to quit \(bundleId) but it isn't running")
            return
        }
        for app in running {
            app.terminate()
        }
        Log.info("Mother: quit \(bundleId)")
    }

    private func blockedAppName(_ bundleId: String) -> String? {
        for entry in store.config.blockedApps where entry.bundleId == bundleId {
            return entry.name.isEmpty ? bundleId : entry.name
        }
        return nil
    }

    // MARK: - Override passes

    private func hasPass(_ table: inout [String: Date], key: String) -> Bool {
        if let until = table[key], until > Date() { return true }
        table[key] = nil
        return false
    }

    private func grantPass(_ table: inout [String: Date], key: String) {
        table[key] = Date().addingTimeInterval(overrideMinutesValue * 60)
    }

    /// Python read this as `cfg("overrideMinutes") or 5` — zero (falsy) also
    /// means the default 5, so replicate that exactly.
    private var overrideMinutesValue: Double {
        let m = store.config.overrideMinutes
        return m == 0 ? 5 : m
    }

    /// Renders 5.0 as "5" (like the Python int default) but keeps a
    /// fractional user value like 7.5 verbatim.
    private var overrideMinutesText: String {
        let m = overrideMinutesValue
        return m == m.rounded() ? String(Int(m)) : String(m)
    }

    // MARK: - Site enforcement (browser tab poller)

    /// Single long-lived loop. It only touches AppleScript while a known
    /// browser is frontmost, so it's idle (and silent) the rest of the time.
    private func sitePollLoop() async {
        while !Task.isCancelled {
            guard let browser = frontBrowser else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let configured = store.config.sitePollSeconds
            let interval = max(1, Int(configured == 0 ? 3 : configured))
            await checkFrontTab(appName: browser.appName, tabPhrase: browser.tabPhrase)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func checkFrontTab(appName: String, tabPhrase: String) async {
        guard let url = await Self.readFrontTab(appName: appName, tabPhrase: tabPhrase) else { return }
        guard let rule = siteBlocked(url) else { return }
        let host = Self.hostOf(url)
        guard !hasPass(&sitePasses, key: host) else { return }
        guard !siteBusy.contains(host) else { return }
        // Per-host backoff so a persistent blocked tab isn't nuked + toasted
        // every poll. (The warn path also toasts, so this covers all modes.)
        let now = ContinuousClock.now
        if let last = siteLastEnforced[host], now - last < Self.siteEnforceCooldown { return }
        siteBusy.insert(host)
        siteLastEnforced[host] = now
        defer { siteBusy.remove(host) }
        await enforceSite(appName: appName, tabPhrase: tabPhrase, host: host, rule: rule)
    }

    private func enforceSite(appName: String, tabPhrase: String, host: String, rule: String) async {
        let mode = currentMode()
        if mode == .off { return }
        if mode == .warn {
            toast("\(rule) is on your blocklist",
                  "Mother sees the tab open in \(appName). Logged.")
            store.record(kind: "site", target: host, action: "warned")
            return
        }

        // Re-read the front tab right before closing it. The match that
        // brought us here came from an earlier poll; between then and now the
        // user may have switched tabs/windows, and `close current tab` acts
        // on whatever is front *now*. Only close if the front tab is still
        // this blocked host — never nuke a tab the user just navigated to.
        guard let fresh = await Self.readFrontTab(appName: appName, tabPhrase: tabPhrase),
              Self.hostOf(fresh) == host
        else {
            Log.info("Mother: front tab changed before close; skipping")
            return
        }

        // Sites are cheaper to undo than apps, so Mother closes the tab first
        // and explains after — even outside focus hours. An override re-opens
        // nothing; it just stops her nagging the same host for a few minutes.
        await Self.closeFrontTab(appName: appName, tabPhrase: tabPhrase)
        store.record(kind: "site", target: host, action: "closed-tab")

        if mode == .enforceNoOverride {
            toast("Mother closed \(host)",
                  "It's blocked and you're in focus hours. Not today.")
            return
        }

        // enforce-override (outside focus hours): offer a quiet pass so
        // re-opening it on purpose doesn't get the tab nuked again instantly.
        // The tab is already closed above; serialize only the negotiation so
        // it can't collide with an app confrontation (single-slot presenter).
        guard !confrontInProgress else { return }
        confrontInProgress = true
        defer { confrontInProgress = false }

        let action = await prompt(
            title: "Mother",
            body: "Closed \(host) — it's on your blocklist. Outside focus "
                + "hours you can buy \(overrideMinutesText) min.",
            actions: ["Keep it blocked", "Override (logged)"],
            timeoutSeconds: 35)
        if action == "Override (logged)" {
            grantPass(&sitePasses, key: host)
            store.record(kind: "site", target: host, action: "override")
            toast("Override granted",
                  "\(overrideMinutesText) minutes on \(host). Re-open the tab yourself.")
        }
    }

    // MARK: - Matching

    /// Extract a lowercase host from a URL. Direct port of `host_of` — kept
    /// string-based (not URLComponents) so edge-case behavior is identical.
    static func hostOf(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://", "ftp://", "file://", "about:"] where u.hasPrefix(scheme) {
            u = String(u.dropFirst(scheme.count))
            break
        }
        for separator: Character in ["/", "?", "#"] {
            if let idx = u.firstIndex(of: separator) {
                u = String(u[..<idx])
            }
        }
        if let at = u.lastIndex(of: "@") {
            u = String(u[u.index(after: at)...])
        }
        if let colon = u.firstIndex(of: ":") {
            u = String(u[..<colon])
        }
        return u
    }

    /// Return the matching blocklist entry, or nil. A rule matches the host
    /// itself and any subdomain of it (reddit.com blocks www.reddit.com) —
    /// host boundaries, not substrings.
    private func siteBlocked(_ url: String) -> String? {
        let host = Self.hostOf(url)
        guard !host.isEmpty else { return nil }
        for rule in store.config.blockedSites {
            var r = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while r.hasPrefix(".") { r.removeFirst() }
            guard !r.isEmpty else { continue }
            if host == r || host.hasSuffix("." + r) { return rule }
        }
        return nil
    }

    // MARK: - AppleScript (Mother's own subprocess, via the automation capability)

    private static func readFrontTab(appName: String, tabPhrase: String) async -> String? {
        let script = "tell application \"\(escapeAS(appName))\" to get URL of \(tabPhrase) of front window"
        let (out, err) = await osascript(script, timeout: 6)
        guard err == nil, let out, !out.isEmpty else { return nil }
        return out
    }

    private static func closeFrontTab(appName: String, tabPhrase: String) async {
        let script = "tell application \"\(escapeAS(appName))\" to close \(tabPhrase) of front window"
        _ = await osascript(script, timeout: 6)
    }

    /// Escape a string for safe embedding inside an AppleScript "..." string
    /// literal. App names come from the user's config.json; a stray quote
    /// would otherwise break out of the literal (and at worst inject script).
    static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run `/usr/bin/osascript -e <script>` off the main actor, with a hard
    /// timeout. Returns (stdout, nil) on success or (nil, message) on any
    /// failure — the same shape the Python `_osascript` helper had.
    nonisolated static func osascript(_ script: String, timeout: Double = 10) async -> (out: String?, err: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (nil, error.localizedDescription))
                    return
                }
                // Watchdog: a hung osascript (e.g. a browser stuck on a modal)
                // is terminated rather than wedging the poll loop forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = (String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let err = (String(data: errData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus != 0 || process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: (nil, err.isEmpty ? "osascript exited \(process.terminationStatus)" : err))
                } else {
                    continuation.resume(returning: (out, nil))
                }
            }
        }
    }

    // MARK: - UI helpers

    private func toast(_ title: String, _ body: String) {
        guard let ui = context.ui else {
            Log.warn("Mother: toast unavailable (notifications capability revoked?)")
            return
        }
        ui.toast(title: "Mother — \(title)", body: body)
    }

    /// nil (no UI service, dismissed, or timed out) is treated by callers the
    /// same way the Python plugin treated a failed/ignored prompt: enforce.
    private func prompt(title: String, body: String, actions: [String],
                        timeoutSeconds: Double) async -> String? {
        guard let ui = context.ui else {
            Log.warn("Mother: prompt unavailable, defaulting to enforce")
            return nil
        }
        return await ui.prompt(title: title, body: body, actions: actions,
                               timeoutSeconds: timeoutSeconds)
    }
}
