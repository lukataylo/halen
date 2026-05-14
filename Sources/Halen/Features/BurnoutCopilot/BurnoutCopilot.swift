import AppKit
import SwiftUI
import Foundation
import CryptoKit

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

    /// Windowed-text hashes already classified this session — avoids re-running
    /// Gemma (and re-recording the same tone sample) on every keystroke pause.
    /// Capped so it can't grow without bound in a long session.
    private var classifiedHashes: Set<String> = []
    private static let maxClassifiedHashes = 256

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
                case .appFocused(let p):
                    self.distraction.note(focused: p.appBundleId)
                    self.refreshSnapshot()
                    self.evaluate()
                case .textPaused(let p) where p.text.count > self.toneMinLength:
                    await self.classifyTone(p.text, caretOffset: p.caretOffset)
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

    private func classifyTone(_ text: String, caretOffset: Int) async {
        let (windowed, _) = windowAroundCaret(text: text, offset: caretOffset, radius: 400)
        guard windowed.count > 40 else { return }

        // Skip text we've already classified this session — the user pausing
        // repeatedly on the same paragraph shouldn't stack tone samples or burn
        // Gemma round-trips.
        let hash = sha256Hex(windowed)
        guard !classifiedHashes.contains(hash) else { return }

        let prompt = """
        Is the tone of the following text irritated, sharp, or hostile? Reply with only "yes" or "no", lowercase.

        Text: \"\"\"\(windowed)\"\"\"
        """
        let request = InferenceRequest(prompt: prompt, tier: .small, maxTokens: 4, temperature: 0.1, taskKind: .classification)
        do {
            let response = try await services.inference.complete(request)
            let answer = response.text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".\""))
            let isSharp = answer.hasPrefix("yes")
            classifiedHashes.insert(hash)
            if classifiedHashes.count > Self.maxClassifiedHashes, let evict = classifiedHashes.first {
                classifiedHashes.remove(evict)
            }
            tone.record(isSharp ? .sharp : .calm)
            refreshSnapshot()
            evaluate()
        } catch {
            Log.debug("BurnoutCopilot tone classify failed: \(error.localizedDescription)")
        }
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

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
        // Try a "Halen Focus" Shortcut (silent if not present).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Shortcuts Events\" to run shortcut \"Halen Focus\""]
        do {
            try task.run()
        } catch {
            Log.debug("BurnoutCopilot: Shortcuts trigger skipped (\(error.localizedDescription))")
        }
    }
}

// MARK: - State

@MainActor
@Observable
final class BurnoutState {
    var distractionMinutes: Int = 0
    var distractionThreshold: Int = 90
    var toneSamples: [ToneTrendTracker.Tone] = []
    var toneSharpCount: Int = 0
    var toneTripThreshold: Int = 3
    var nextFourHourEvents: Int = 0
    var hasBackToBackSoon: Bool = false
    var calendarTripThreshold: Int = 3
    var nextEventTitle: String?
    var nextEventStart: Date?
    var calendarHasAccess: Bool = false

    var signalA = false
    var signalB = false
    var signalC = false
    var lastEvaluated: Date?
}
