import AppKit
import SwiftUI
import Foundation

/// Watches three signals — distraction-app time, recent writing tone, calendar
/// density — and surfaces a "Take 10?" popup when ≥2 of 3 trip thresholds.
/// One-button shortcut creates a 10-min calendar break and attempts to trigger
/// a Focus shortcut named "Halen Focus".
@MainActor
final class BurnoutCopilot: HalenPlugin {
    let id = "com.halen.burnout-copilot"
    let name = "Burnout Copilot"
    let summary = "Suggests a break when your apps, tone, and calendar all say you've been at it too long."
    let icon = "brain.head.profile"
    let category: PluginCategory = .focus

    private let services: HalenServices
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var activePanel: NSPanel?

    /// Owns the typing-settle debounce, paragraph extraction and dedup of
    /// recently-seen paragraphs — the shared scaffolding SentimentGuard also
    /// uses. Tone-tracking, the prompt, and the snapshot/evaluate orchestration
    /// stay here.
    private let toneClassifier = ParagraphClassifier(minLength: 40)

    let state = BurnoutState()
    private let distraction = DistractionTimeTracker()
    private let tone = ToneTrendTracker()
    private let calendar = CalendarDensityTracker()
    private var cooldownUntil: Date = .distantPast

    /// Per-message minimum length before we send the text to Gemma for tone.
    private let toneMinLength = 60
    private let distractionThresholdMinutes = 90
    private let calendarDenseThreshold = 3

    init(services: HalenServices) {
        self.services = services
    }

    func start() {
        guard eventTask == nil else { return }
        setupTask = Task { @MainActor [calendar, weak self] in
            await calendar.requestAccess()
            guard !Task.isCancelled else { return }
            self?.refreshSnapshot()
        }
        subscribeToEvents()
        startHeartbeat()
        Log.info("BurnoutCopilot started")
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        setupTask?.cancel()
        setupTask = nil
        toneClassifier.cancel()
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    func makeDetailView() -> AnyView {
        AnyView(BurnoutCopilotDetailView(
            state: state,
            onForceEvaluate: { [weak self] in
                self?.refreshSnapshot()
                self?.evaluate(force: true)
            }
        ))
    }

    // MARK: - Wiring

    private func subscribeToEvents() {
        eventTask = Task { @MainActor [services, weak self] in
            for await event in services.eventBus.subscribe() {
                guard let self else { return }
                switch event {
                case .appFocused(let payload):
                    self.distraction.note(focused: payload.appBundleId)
                    self.refreshSnapshot()
                    self.evaluate()
                case .textPaused(let payload) where payload.text.count > self.toneMinLength:
                    self.scheduleToneClassification(text: payload.text, caretOffset: payload.caretOffset)
                default:
                    break
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard let self else { return }
                self.refreshSnapshot()
                self.evaluate()
            }
        }
    }

    // MARK: - Tone classification

    /// Hand off to `ParagraphClassifier` — settle-debounce, paragraph extraction
    /// and dedup all live there. The closure carries BurnoutCopilot's specific
    /// step: a yes/no prompt to Gemma whose answer feeds the tone trend.
    private func scheduleToneClassification(text: String, caretOffset: Int) {
        toneClassifier.schedule(
            text: text,
            caretOffset: caretOffset,
            classify: { [weak self] paragraph in
                await self?.runToneClassification(paragraph: paragraph)
            }
        )
    }

    /// The Gemma half: yes/no on whether `paragraph` reads as sharp/hostile.
    /// Result feeds `tone.record(...)`, which `evaluate()` then turns into one
    /// of the three "Take 10?" trip signals.
    private func runToneClassification(paragraph: String) async {
        let prompt = """
        Is the tone of the following text irritated, sharp, or hostile? Reply with only "yes" or "no", lowercase.

        Text: \"\"\"\(paragraph)\"\"\"
        """
        // maxTokens 16, not 4: the bundled llama.cpp backend wraps the prompt in
        // the Gemma chat template, which can emit a leading newline/space token
        // before content. A 4-token budget can be spent before "yes"/"no" lands,
        // yielding an empty completion and a silently-dropped tone sample.
        let request = InferenceRequest(prompt: prompt, tier: .small, maxTokens: 16,
                                       temperature: 0.1, taskKind: .classification)
        do {
            let response = try await services.inference.complete(request)
            let answer = response.text.modelLabelToken
            tone.record(answer.hasPrefix("yes") ? .sharp : .calm)
            refreshSnapshot()
            evaluate()
        } catch {
            Log.debug("BurnoutCopilot tone classify failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Evaluation

    private func refreshSnapshot() {
        state.distractionMinutes = distraction.distractionMinutesInWindow
        state.distractionThreshold = distractionThresholdMinutes
        state.toneSamples = tone.window
        state.toneSharpCount = tone.sharpCount
        state.toneTripThreshold = 3
        let density = calendar.snapshot()
        state.nextFourHourEvents = density.nextFourHourEvents
        state.hasBackToBackSoon = density.hasBackToBackSoon
        state.calendarTripThreshold = calendarDenseThreshold
        state.nextEventTitle = density.nextEventTitle
        state.nextEventStart = density.nextEventStart
        state.calendarHasAccess = calendar.hasAccess
    }

    private func evaluate(force: Bool = false) {
        if !force, Date() < cooldownUntil { return }
        let signalA = state.distractionMinutes >= state.distractionThreshold
        let signalB = state.toneSharpCount >= state.toneTripThreshold
        let signalC = state.nextFourHourEvents >= state.calendarTripThreshold || state.hasBackToBackSoon

        let tripped = [signalA, signalB, signalC].filter { $0 }.count
        state.signalA = signalA
        state.signalB = signalB
        state.signalC = signalC
        state.lastEvaluated = Date()

        if tripped >= 2 || force {
            showPopup(signalA: signalA, signalB: signalB, signalC: signalC)
            cooldownUntil = Date().addingTimeInterval(30 * 60)
        }
    }

    // MARK: - Popup

    private func showPopup(signalA: Bool, signalB: Bool, signalC: Bool) {
        activePanel?.orderOut(nil)
        let width: CGFloat = 360
        let height: CGFloat = 220
        // Transient suggestion popover with Accept/Dismiss — floating, interactive.
        let panel = HalenFloatingPanel.make(
            size: NSSize(width: width, height: height),
            level: .floating,
            interactive: true,
            shadow: true
        )

        let message = makeMessage(signalA: signalA, signalB: signalB, signalC: signalC)
        let view = BurnoutCopilotPopup(
            message: message,
            onAccept: { [weak self] in
                self?.acceptBreak()
                self?.closePopup()
            },
            onDismiss: { [weak self] in self?.closePopup() }
        )
        panel.contentView = NSHostingView(rootView: view)

        if let screen = NSScreen.main {
            let x = screen.frame.maxX - width - 20
            let y = screen.frame.minY + 80
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        panel.orderFrontRegardless()
        activePanel = panel
    }

    private func closePopup() {
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    private func makeMessage(signalA: Bool, signalB: Bool, signalC: Bool) -> String {
        var parts: [String] = []
        if signalA { parts.append("\(state.distractionMinutes)min in distraction apps") }
        if signalB { parts.append("recent writing reads sharp") }
        if signalC {
            if state.hasBackToBackSoon {
                parts.append("back-to-back meetings soon")
            } else {
                parts.append("\(state.nextFourHourEvents) meetings in the next 4h")
            }
        }
        if parts.isEmpty {
            // Force-evaluate from the detail view's demo button: nothing has
            // tripped, but show something so the popup still demonstrates.
            return "Demo trigger. A real suggestion fires when 2 of 3 signals trip — give it time or rack up some Slack minutes first."
        }
        return parts.joined(separator: " · ")
    }

    private func acceptBreak() {
        let created = calendar.createBreakEvent()
        if created {
            Log.info("BurnoutCopilot: created 🌿 Halen break event")
        }
        // Fire the optional "Halen Focus" Shortcut off the main actor.
        // `Process.run()` is a fork/exec — cheap, but no reason to do it on
        // the UI thread. The detached task also `waitUntilExit()`s so the
        // child is reaped rather than left as a zombie if the Shortcut hangs.
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Shortcuts Events\" to run shortcut \"Halen Focus\""]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                Log.debug("BurnoutCopilot: Shortcuts trigger skipped (\(error.localizedDescription))")
            }
        }
    }
}

// MARK: - State

/// Reactive snapshot for the BurnoutCopilot detail view. Only `BurnoutCopilot`
/// (same file) writes; the view reads. `fileprivate(set)` enforces the one-
/// writer rule without forcing a wrapper method per field.
@MainActor
@Observable
final class BurnoutState {
    fileprivate(set) var distractionMinutes: Int = 0
    fileprivate(set) var distractionThreshold: Int = 90
    fileprivate(set) var toneSamples: [ToneTrendTracker.Tone] = []
    fileprivate(set) var toneSharpCount: Int = 0
    fileprivate(set) var toneTripThreshold: Int = 3
    fileprivate(set) var nextFourHourEvents: Int = 0
    fileprivate(set) var hasBackToBackSoon: Bool = false
    fileprivate(set) var calendarTripThreshold: Int = 3
    fileprivate(set) var nextEventTitle: String?
    fileprivate(set) var nextEventStart: Date?
    fileprivate(set) var calendarHasAccess: Bool = false

    fileprivate(set) var signalA = false
    fileprivate(set) var signalB = false
    fileprivate(set) var signalC = false
    fileprivate(set) var lastEvaluated: Date?
}
