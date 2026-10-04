import EQCore
import Foundation
import ServiceManagement
import SwiftUI

/// Owns the session lifecycle: notice a call, listen to your side, turn it
/// into numbers, forget the audio, ask how it went.
@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle, starting(source: String?), listening(source: String?, since: Date), analysing
    }

    enum Enrollment: Equatable {
        case idle, recording(progress: Double), processing, done, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var detectedCall: CallDetector.Call?
    @Published private(set) var voicePrint: VoicePrint?
    @Published private(set) var enrollment: Enrollment = .idle
    /// Recent levels for the dot-matrix waveform (10 Hz, ~6 s).
    /// Live levels live in their own object so 10 Hz updates only redraw
    /// the waveform, not every window observing the model.
    let live = LiveMeter()
    /// Paused by the user ("for an hour" / "until tomorrow"): calls are ignored.
    @Published private(set) var pausedUntil: Date?
    /// The voice check threw away most of the last call: probably a new mic.
    @Published var voiceMismatch = false
    /// A call the user stopped or discarded by hand: leave it alone until it ends.
    private var ignoredCall: String?
    private var enrollFinishRequested = false
    @Published var lastError: String?

    @AppStorage("autoStart") var autoStart = true
    @AppStorage("appModes") private var appModesJSON = "{}"
    /// What dedicated call apps do by default; chosen in the welcome window.
    @AppStorage("defaultCallMode") var defaultCallMode = AppMode.ask.rawValue

    /// Per-app behaviour when that app takes the mic.
    enum AppMode: String, Codable, CaseIterable, Identifiable {
        case auto, ask, off
        var id: String { rawValue }
        var title: String { switch self { case .auto: "Listen automatically"; case .ask: "Ask first"; case .off: "Never" } }
    }

    func mode(for bundleID: String) -> AppMode {
        let stored = (try? JSONDecoder().decode([String: AppMode].self, from: Data(appModesJSON.utf8)))?[bundleID]
        if let stored { return stored }
        return CallDetector.isBrowser(bundleID) ? .ask : (AppMode(rawValue: defaultCallMode) ?? .ask)
    }

    func setMode(_ mode: AppMode, for bundleID: String) {
        var all = (try? JSONDecoder().decode([String: AppMode].self, from: Data(appModesJSON.utf8))) ?? [:]
        all[bundleID] = mode
        appModesJSON = String(decoding: try! JSONEncoder().encode(all), as: UTF8.self)
        objectWillChange.send()
    }

    /// Call apps installed on this Mac, for the per-app list in Settings.
    var installedCallApps: [String] {
        CallDetector.callApps.keys
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            .sorted { (CallDetector.isBrowser($0) ? 1 : 0, $0) < (CallDetector.isBrowser($1) ? 1 : 0, $1) }
    }
    /// Off by default; only possible once the voice check is set up.
    @AppStorage("saveTranscripts") var saveTranscripts = false { didSet { transcriptSettingChanged() } }
    @AppStorage("transcriptDays") var transcriptDays = 7 { didSet { enforceRetention() } }

    private(set) var baseline = Baseline()
    private let store: SessionStore?
    private let detector = CallDetector()
    private let coach = Coach()
    private var voiceCheck: VoiceCheck?
    private var mic: MicCapture?
    private var tap: FarEndTap?
    private var pipeline: SessionPipeline?
    private var feeder: Task<Void, Never>?
    private var meterTimer: Timer?
    private var retentionTimer: Timer?
    let ratingPanel = RatingPanelController()

    /// `EQ_DEMO=1` (debug builds only): throwaway store with sample calls, no
    /// call detection — for screenshots and design work without real data.
    #if DEBUG
    static let isDemo = ProcessInfo.processInfo.environment["EQ_DEMO"] == "1"
    #else
    static let isDemo = false
    #endif

    /// First launch: the welcome window explains the menu bar icon and asks
    /// how calls should start. Until then auto-listen is off.
    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: "onboarded") && !isDemo }

    init() {
        #if DEBUG
        if Self.isDemo {
            store = try? SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("HalenEQ-demo-\(UUID())"),
                                      key: .init(size: .bits256))
            Demo.seed(store)
            sessions = store?.all() ?? []
            ratingPanel.model = self
            if ProcessInfo.processInfo.environment["EQ_DEMO_LISTEN"] == "1" {
                // Fake a live call for screenshots of the listening state.
                state = .listening(source: "us.zoom.xos", since: .now.addingTimeInterval(-252))
                var t = 0
                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        t += 1
                        let mine = t % 40 < 22
                        self?.live.push(you: mine ? Float.random(in: -40 ... -18) : -60, them: mine ? -70 : Float.random(in: -42 ... -20))
                    }
                }
            } else if let first = sessions.first { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ratingPanel.present(first.id) } }
            return
        }
        #endif
        do { store = try SessionStore() } catch { store = nil; lastError = "Couldn't open storage: \(error.localizedDescription)" }
        baseline = Self.loadBaseline()
        voicePrint = store?.loadVoicePrint()
        refresh()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforceRetention() }
        }
        detector.onChange = { [weak self] call in self?.callChanged(call) }
        detector.start()
        ratingPanel.model = self
    }

    var isListening: Bool { if case .listening = state { true } else { false } }
    var today: [SessionRecord] { sessions.filter { Calendar.current.isDateInToday($0.startedAt) } }
    var lastUnrated: SessionRecord? {
        sessions.first.flatMap { $0.rating == nil && Date.now.timeIntervalSince($0.startedAt) < 6 * 3600 ? $0 : nil }
    }
    func session(_ id: UUID) -> SessionRecord? { sessions.first { $0.id == id } }

    // MARK: Call detection

    private func callChanged(_ call: CallDetector.Call?) {
        detectedCall = call
        if call == nil { ignoredCall = nil }
        if let until = pausedUntil, until <= .now { pausedUntil = nil }
        guard autoStart, !Self.needsOnboarding, pausedUntil == nil, call?.bundleID != ignoredCall || call == nil else { return }
        switch (call, state) {
        case (let c?, .idle):
            switch mode(for: c.bundleID) {
            case .auto: Task { await start(source: c.bundleID) }
            case .ask: ratingPanel.ask(c)
            case .off: break
            }
        case (nil, .listening(let src, _)) where src != nil,
             (nil, .starting(let src)) where src != nil:
            Task { await stop() }
        default: break
        }
    }

    // MARK: Sessions

    private var isEnrolling: Bool {
        switch enrollment { case .recording, .processing: true; default: false }
    }

    func start(source: String?) async {
        // Never listen during voice setup: a call's audio would end up in the voice print.
        guard state == .idle, !isEnrolling else { return }
        // Claim the slot *before* any await so a second start (or a stop for
        // a call that already ended) can't interleave.
        state = .starting(source: source)
        func stillWanted() -> Bool { state == .starting(source: source) }

        guard await MicCapture.requestPermission() else {
            lastError = "Microphone access is off — System Settings › Privacy & Security › Microphone."
            state = .idle; return
        }
        if let voicePrint, voiceCheck == nil {
            do { voiceCheck = try await VoiceCheck.load(print: voicePrint) }
            catch { lastError = "Voice check couldn't load — other voices may be included. (\(error.localizedDescription))" }
        }
        var p = SessionPipeline(voiceCheck: voiceCheck, transcriber: AppleTranscriber())
        do { try await p.start() } catch {
            lastError = "Speech recognition unavailable — measuring voice only."
            p = SessionPipeline(voiceCheck: voiceCheck, transcriber: nil)
        }
        guard stillWanted() else {
            _ = try? await p.finish(other: nil)   // shut the analyzer down cleanly
            if case .starting = state { state = .idle }
            return
        }

        let mic = MicCapture()
        do {
            let chunks = try mic.start()
            let pipe = p
            feeder = Task { for await c in chunks { await pipe.ingest(c) } }
        } catch {
            lastError = "Couldn't open the microphone: \(error.localizedDescription)"
            _ = try? await p.finish(other: nil)
            state = .idle; return
        }
        // Level-only meter on the call app. Optional: if permission is denied
        // or the app isn't playing audio yet, Presence just has fewer factors.
        if let source {
            let t = FarEndTap()
            if (try? t.start(bundleID: source)) != nil { tap = t }
        }
        self.mic = mic
        pipeline = p
        lastError = nil
        state = .listening(source: source, since: .now)
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let mic = self.mic else { return }
                self.live.push(you: mic.currentLevel, them: self.tap?.currentLevel)
            }
        }
    }

    /// `discard`: end now and keep nothing from this call. Either way, a call
    /// that's still going won't restart listening until it ends.
    func stop(discard: Bool = false) async {
        if case .starting = state { state = .idle; return }   // start() sees this and bails
        guard case .listening(let source, let since) = state, let pipeline else { return }
        meterTimer?.invalidate(); meterTimer = nil
        let origin = mic?.origin
        mic?.stop(); mic = nil
        // Always tear the tap down, even if no mic audio ever arrived.
        let spans = tap?.stop(origin: origin ?? HostTime.now)
        let other = origin == nil ? nil : spans
        tap = nil
        live.reset()
        ignoredCall = detectedCall?.bundleID
        state = .analysing
        await feeder?.value   // drain every captured chunk before finishing
        feeder = nil
        var saved: SessionRecord?
        do {
            let (metrics, words) = try await pipeline.finish(other: other)
            voiceMismatch = metrics.voiceChecked && metrics.ignoredSeconds > 60 && metrics.ignoredSeconds > 3 * metrics.speakingSeconds
            if !discard, metrics.speakingSeconds >= 20 {   // otherwise a mic blip, not a conversation
            let keepWords = saveTranscripts && metrics.voiceChecked && !words.isEmpty
            let record = SessionRecord(startedAt: since, source: source, metrics: metrics,
                                       scores: ScoreCard(metrics: metrics, baseline: baseline),
                                       words: keepWords ? words : nil)
            baseline.absorb(metrics)
            Self.saveBaseline(baseline)
            try store?.save(record)
            sessions.insert(record, at: 0)
            saved = record
            }
        } catch {
            lastError = "Analysis failed: \(error.localizedDescription)"
        }
        // Back to idle *before* the (slow) coach runs, so a back-to-back call
        // is picked up — and re-check, since the detector only fires on change.
        state = .idle
        self.pipeline = nil
        if let call = detectedCall { callChanged(call) }
        if var record = saved {
            ratingPanel.present(record.id)
            record.takeaway = await coach.takeaway(for: record)
            update(record.id) { $0.takeaway = record.takeaway }
        }
    }

    // MARK: Feedback

    func rate(_ id: UUID, _ rating: Double, note: String?) {
        update(id) { $0.rating = rating; $0.note = note?.isEmpty == false ? note : nil }
    }

    /// "That's not right" — the factor drops out of this session's score, the
    /// weekly focus, and the takeaway.
    func toggleDispute(_ id: UUID, factor: String) {
        update(id) { r in if r.disputed.contains(factor) { r.disputed.remove(factor) } else { r.disputed.insert(factor) } }
    }

    func delete(_ id: UUID) { store?.delete(id); sessions.removeAll { $0.id == id } }

    /// Patch one record in memory and on disk — no full reload.
    private func update(_ id: UUID, _ change: (inout SessionRecord) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        try? store?.save(sessions[i])
    }

    // MARK: Voice check

    /// 30 s of reading aloud builds the voice print *and* the calm-voice
    /// pitch reference for Composure — one step instead of two.
    func enroll() async {
        guard state == .idle else { lastError = "Finish your call first."; return }
        guard !isEnrolling else { return }
        guard await MicCapture.requestPermission() else { enrollment = .failed("Microphone access is off."); return }
        let mic = MicCapture()
        let collector: Task<[Float], Never>
        do {
            let chunks = try mic.start()
            collector = Task { var all: [Float] = []; for await c in chunks { all += c }; return all }
        } catch { enrollment = .failed(error.localizedDescription); return }

        // Stop as soon as there's enough of you: ~15 s of speech, then a pause
        // (or "Done"). Hard limit 45 s.
        enrollFinishRequested = false
        let enoughTicks = 60, maxTicks = 180   // 4 Hz
        var speechTicks = 0, quietRun = 0
        for _ in 0 ..< maxTicks {
            // A call started (or a session began) mid-setup: abandon rather
            // than learn someone else's voice.
            if state != .idle || detectedCall.map({ !$0.isBrowser }) == true {
                mic.stop(); _ = await collector.value; live.reset()
                enrollment = .failed("A call started — try again when you're off the call.")
                return
            }
            let level = mic.currentLevel
            if level > -42 { speechTicks += 1; quietRun = 0 } else { quietRun += 1 }
            enrollment = .recording(progress: min(1, Double(speechTicks) / Double(enoughTicks)))
            live.push(you: level, them: nil)
            if speechTicks >= enoughTicks && quietRun >= 6 { break }          // finished the passage
            if enrollFinishRequested && speechTicks >= enoughTicks * 2 / 3 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        mic.stop()
        live.reset()
        let samples = await collector.value
        enrollment = .processing
        do {
            let check = try await VoiceCheck.load(print: nil)
            let print = try await check.enroll(samples)
            try store?.saveVoicePrint(print)
            voiceCheck = check
            voicePrint = print

            var prosody = ProsodyExtractor()
            let m = MetricsBuilder.build(frames: prosody.process(samples), words: [], other: nil,
                                         duration: Double(samples.count) / ProsodyExtractor.sampleRate)
            baseline.calmPitchSt = RunningStat()
            for w in m.windows where w.speaking > 0.5 { if let p = w.pitchSt { baseline.calmPitchSt.add(Double(p)) } }
            Self.saveBaseline(baseline)
            voiceMismatch = false
            enrollment = .done
        } catch {
            enrollment = .failed(error.localizedDescription)
        }
    }

    /// Welcome window finished: remember the choice, ask for the mic now —
    /// in context — rather than in the middle of someone's first call.
    func finishOnboarding(mode: AppMode) async {
        defaultCallMode = mode.rawValue
        UserDefaults.standard.set(true, forKey: "onboarded")
        _ = await MicCapture.requestPermission()
        objectWillChange.send()
    }

    func finishEnrollmentEarly() { enrollFinishRequested = true }

    func pause(until date: Date?) { pausedUntil = date }

    func resetEnrollmentState() { if enrollment != .processing { enrollment = .idle } }

    func deleteVoicePrint() {
        store?.deleteVoicePrint()
        voicePrint = nil
        voiceCheck = nil
        saveTranscripts = false
    }

    // MARK: Privacy

    private func transcriptSettingChanged() {
        guard !saveTranscripts, sessions.contains(where: { $0.words != nil }) else { return }
        for i in sessions.indices where sessions[i].words != nil {
            sessions[i].words = nil
            try? store?.save(sessions[i])
        }
    }

    /// Runs on launch, hourly, and when the setting changes — a menubar app
    /// can stay up for weeks.
    func enforceRetention() {
        // Nothing to expire unless some session still has words — skip the
        // (decrypt-everything) disk pass entirely in the common case.
        let cutoff = Date.now.addingTimeInterval(-Double(transcriptDays) * 86_400)
        for i in sessions.indices where sessions[i].words != nil && sessions[i].startedAt < cutoff {
            sessions[i].words = nil
            try? store?.save(sessions[i])
        }
    }

    func forgetEverything() {
        try? store?.forgetAll()
        baseline = Baseline()
        Self.saveBaseline(baseline)
        voicePrint = nil
        voiceCheck = nil
        saveTranscripts = false
        sessions = []
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { lastError = "Couldn't change login item: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }

    /// Full load from disk, off the main thread (decrypting hundreds of
    /// sessions takes seconds). Also purges undecryptable files once.
    private func refresh() {
        guard let store else { return }
        let days = transcriptDays
        Task.detached(priority: .utility) {
            _ = try? store.enforce(transcriptDays: days)
            let all = store.all()
            await MainActor.run { self.sessions = all }
        }
    }

    // Baseline is a mean and variance of pitch — fine in defaults.
    private static func loadBaseline() -> Baseline {
        guard let d = UserDefaults.standard.data(forKey: "baseline"),
              let b = try? JSONDecoder().decode(Baseline.self, from: d) else { return Baseline() }
        return b
    }

    private static func saveBaseline(_ b: Baseline) {
        UserDefaults.standard.set(try? JSONEncoder().encode(b), forKey: "baseline")
    }
}
