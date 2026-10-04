import CryptoKit
import Foundation
import Testing
@testable import EQCore

func sine(_ hz: Double, seconds: Double, amp: Float = 0.3, glideTo: Double? = nil) -> [Float] {
    let n = Int(seconds * 16_000)
    var phase = 0.0
    return (0 ..< n).map { i in
        let f = glideTo.map { hz + ($0 - hz) * Double(i) / Double(n) } ?? hz
        phase += 2 * .pi * f / 16_000
        // A few harmonics so it's voice-ish, not a pure tone.
        return amp * Float(sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75
    }
}

/// 1024 samples of two summed sines — split out so slower CI compilers
/// don't time out type-checking one long closure.
func twoTone(_ f1: Double, _ f2: Double, _ a2: Float) -> [Float] {
    (0 ..< 1_024).map { (i: Int) -> Float in
        let t = Double(i) / 16_000
        let a = Float(sin(2 * Double.pi * f1 * t))
        let b = Float(sin(2 * Double.pi * f2 * t))
        return a + a2 * b
    }
}

func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

@Suite struct ProsodyTests {
    @Test(arguments: [80.0, 120.0, 200.0, 310.0])
    func yinFindsPitch(hz: Double) throws {
        let f0 = try #require(ProsodyExtractor.yin(Array(sine(hz, seconds: 0.064))))
        #expect(abs(Double(f0) - hz) / hz < 0.02)
    }

    /// Regression: a two-tone mix (521 Hz + 2724 Hz partial) once produced
    /// f0 = -2323 Hz → NaN semitones → crash in Score.init.
    @Test func yinNeverReturnsOutOfRange() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 3_000 {
            let f1 = Double.random(in: 40 ... 900, using: &rng), f2 = Double.random(in: 40 ... 4_000, using: &rng)
            let a2 = Float.random(in: 0 ... 1, using: &rng)
            let x = twoTone(f1, f2, a2)
            if let f0 = ProsodyExtractor.yin(x) { #expect(f0.isFinite && f0 >= 57 && f0 <= 525) }
        }
        let bad = twoTone(521, 2_724, 0.2)
        if let f0 = ProsodyExtractor.yin(bad) { #expect(f0 > 0) }
    }

    @Test func silenceIsUnvoiced() {
        var p = ProsodyExtractor()
        let frames = p.process(silence(0.5))
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.f0 == nil })
    }

    @Test func framesAreContinuousAcrossChunks() {
        var a = ProsodyExtractor(), b = ProsodyExtractor()
        let x = sine(150, seconds: 1)
        let whole = a.process(x)
        let parts = b.process(Array(x[0 ..< 7_000])) + b.process(Array(x[7_000...]))
        #expect(whole.count == parts.count)
        #expect(zip(whole, parts).allSatisfy { abs($0.t - $1.t) < 1e-9 })
    }

    @Test func semitones() {
        #expect(abs(Pitch.semitones(200) - 12) < 1e-4)
        #expect(abs(Pitch.semitones(100)) < 1e-4)
    }
}

@Suite struct ActivityTests {
    @Test func speechSpansFindsBursts() {
        var p = ProsodyExtractor()
        let audio = silence(1) + sine(150, seconds: 2) + silence(1) + sine(150, seconds: 1) + silence(1)
        let spans = Activity.speechSpans(p.process(audio))
        #expect(spans.count == 2)
        #expect(abs(spans[0].start - 1) < 0.08 && abs(spans[0].end - 3) < 0.08)
    }

    @Test func turnsSplitWhenOtherSpeaks() {
        let own = [Span(0, 5), Span(5.8, 9)]
        #expect(Activity.turns(own: own, other: nil).count == 1)
        #expect(Activity.turns(own: own, other: [Span(5.0, 5.7)]).count == 2)
    }

    @Test func interruptionAndLatency() {
        let other = [Span(0, 10), Span(20, 25)]
        let own = [Span(8, 15), Span(25.4, 30)]   // cut in at 8 s; replied 0.4 s after they finished at 25
        #expect(MetricsBuilder.interruptions(own: own, other: other) == 1)
        let lat = MetricsBuilder.responseLatencies(own: own, other: other)
        #expect(lat.contains { abs($0 - 0.4) < 1e-9 })
    }
}

@Suite struct ToneTests {
    func words(_ s: String) -> [Word] {
        s.split(separator: " ").enumerated().map { Word(text: String($1), start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
    }

    @Test func sentimentReadsYourWords() throws {
        let happy = try #require(Tone.sentiment(words("That is wonderful news, thank you so much. I really love how this turned out, it is a great result for everyone.")))
        let sad = try #require(Tone.sentiment(words("This is terrible and I am really upset. Honestly it was an awful mess and a complete disaster for the whole team.")))
        #expect(happy > 0.15 && sad < -0.15)
        #expect(Tone.mood(happy) == .positive && Tone.mood(sad) == .negative)
    }

    @Test func tooFewWordsGivesNoTone() {
        #expect(Tone.sentiment(words("Okay great thanks")) == nil)
    }
}

@Suite struct FilledPauseTests {
    @Test func flatHumIsAFiller() {
        var p = ProsodyExtractor()
        // A gliding "word", gap, then a flat 0.5 s "uhh" at the same pitch.
        let audio = silence(0.5) + sine(140, seconds: 0.6, glideTo: 190) + silence(0.4)
            + sine(130, seconds: 0.5) + silence(0.5)
        let frames = p.process(audio)
        let found = FilledPauses.detect(frames: frames, words: [Word(text: "hello", start: 0.5, end: 1.1)])
        #expect(found.count == 1)
        if let f = found.first { #expect(f.start > 1.4 && f.end < 2.1) }
    }

    @Test func recognisedWordIsNotAFiller() {
        var p = ProsodyExtractor()
        let frames = p.process(silence(0.3) + sine(130, seconds: 0.5) + silence(0.3))
        let found = FilledPauses.detect(frames: frames, words: [Word(text: "so", start: 0.3, end: 0.8)])
        #expect(found.isEmpty)
    }
}

func metrics(speaking: Double = 300, _ edit: (inout SessionMetrics) -> Void = { _ in }) -> SessionMetrics {
    var m = MetricsBuilder.build(frames: [], words: [], other: nil, duration: 600)
    m.speakingSeconds = speaking
    edit(&m)
    return m
}

@Suite struct ScoringTests {
    @Test func welford() {
        var s = RunningStat()
        [2, 4, 4, 4, 5, 5, 7, 9].forEach { s.add(Double($0)) }
        #expect(abs(s.mean - 5) < 1e-9)
        #expect(abs(s.sd - 2.138) < 1e-3)
    }

    @Test func tooLittleSpeechGivesNoScore() {
        #expect(ScoreCard(metrics: metrics(speaking: 60) { $0.wpm = 150 }, baseline: Baseline()).clarity.value == nil)
    }

    @Test func spikeNeedsTwoChannelsAndTwoWindows() {
        func w(_ i: Int, pitch: Float, db: Float) -> WindowSummary {
            WindowSummary(start: Double(i) * 5, speaking: 1, pitchSt: pitch, db: db, wpm: 150)
        }
        // Calm at 8 st / -30 dB, one isolated loud+high window, then a 2-window episode.
        var ws = (0 ..< 20).map { w($0, pitch: 8 + Float($0 % 3) * 0.5, db: -30) }
        ws[5] = w(5, pitch: 14, db: -20)
        ws[12] = w(12, pitch: 14, db: -20); ws[13] = w(13, pitch: 14, db: -20)
        #expect(Composure.analyse(ws, calm: Baseline()).spikeWindows == 2)
    }

    @Test func perfectSessionScoresHigh() {
        let card = ScoreCard(metrics: metrics {
            $0.wpm = 150; $0.fillersPer100 = 2; $0.pitchSdSt = 3.2
            $0.longestTurn = 40; $0.talkRatio = 0.5; $0.interruptionsPer10Min = 0
        }, baseline: Baseline())
        #expect(card.clarity.value == 100)
        #expect(card.presence.value == 100)
    }

    @Test func monologuingHurtsPresence() {
        let m = metrics(speaking: 500) { $0.longestTurn = 240; $0.turnsOver90s = 2; $0.talkRatio = 0.85; $0.interruptionsPer10Min = 4 }
        #expect((ScoreCard(metrics: m, baseline: Baseline()).presence.value ?? 100) < 30)
    }

    @Test func disputedFactorStopsCounting() {
        let card = ScoreCard(metrics: metrics { $0.wpm = 230; $0.fillersPer100 = 2; $0.pitchSdSt = 3 }, baseline: Baseline())
        let before = try! #require(card.clarity.value)
        let after = try! #require(card.without(["pace"]).clarity.value)
        #expect(before < 100 && after == 100)
        #expect(card.without(["pace"]).clarity.factors.count == 3)   // still shown, just not counted
    }
}

@Suite struct InsightTests {
    func record(daysAgo: Double = 0, rating: Double?, monologues: Int, pace: Double = 150) -> SessionRecord {
        let m = metrics { $0.turnsOver90s = monologues; $0.wpm = pace; $0.fillersPer100 = 2; $0.pitchSdSt = 3 }
        var r = SessionRecord(startedAt: .now.addingTimeInterval(-daysAgo * 86_400), source: nil, metrics: m,
                              scores: ScoreCard(metrics: m, baseline: Baseline()), words: nil)
        r.rating = rating
        return r
    }

    @Test func learnsWhatPredictsYourGoodCalls() throws {
        // Fewer monologues ↔ higher ratings; pace is noise.
        let rs = (0 ..< 8).map { i in record(rating: Double(i) / 7, monologues: 7 - i, pace: [140, 160][i % 2]) }
        let link = try #require(Insights.whatPredictsGoodCalls(rs))
        #expect(link.factorID == "monologue")
    }

    @Test func needsSixRatedCalls() {
        let rs = (0 ..< 5).map { i in record(rating: Double(i) / 4, monologues: 4 - i) }
        #expect(Insights.whatPredictsGoodCalls(rs) == nil)
    }

    @Test func focusIsThisWeekOnlyAndCanBeNothing() {
        let old = (0 ..< 3).map { _ in record(daysAgo: 10, rating: nil, monologues: 5) }
        #expect(Insights.focus(old) == nil)
        let fine = (0 ..< 3).map { _ in record(rating: nil, monologues: 0) }
        #expect(Insights.focus(fine) == nil)
        let recent = (0 ..< 3).map { _ in record(rating: nil, monologues: 5) }
        #expect(Insights.focus(recent)?.id == "monologue")
    }

    @Test func disputedFactorsLeaveTheFocus() {
        var rs = (0 ..< 3).map { _ in record(rating: nil, monologues: 5) }
        for i in rs.indices { rs[i].disputed = ["monologue"] }
        #expect(Insights.focus(rs) == nil)
    }
}

@Suite struct FarEndTests {
    @Test func levelsBecomeSpans() {
        // 10 ms steps: talk 0–1 s, short 0.2 s dip (merged), talk to 2 s, silence.
        let levels: [(t: Double, db: Float)] = (0 ..< 300).map { i in
            let t = Double(i) / 100
            let talking = (t < 1.0) || (t >= 1.2 && t < 2.0)
            return (t, talking ? -20 : -80)
        }
        let spans = FarEndTap.spans(levels)
        #expect(spans.count == 1)
        #expect(abs(spans[0].start) < 0.02 && abs(spans[0].end - 2.0) < 0.02)
    }
}

@Suite struct StoreTests {
    func makeStore() throws -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions")
        return (try SessionStore(directory: dir, key: SymmetricKey(size: .bits256)), dir)
    }

    @Test func roundTripAndRetention() throws {
        let (store, dir) = try makeStore()
        let m = metrics()
        var old = SessionRecord(startedAt: .now.addingTimeInterval(-40 * 86_400), source: nil, metrics: m,
                                scores: ScoreCard(metrics: m, baseline: Baseline()), words: [Word(text: "secret", start: 0, end: 1)])
        old.rating = 0.8; old.disputed = ["pace"]
        try store.save(old)
        // On disk it is ciphertext, not JSON.
        let blob = try Data(contentsOf: dir.appendingPathComponent("\(old.id.uuidString).eqs"))
        #expect(String(data: blob, encoding: .utf8)?.contains("secret") != true)

        #expect(try store.enforce(transcriptDays: 30) == 1)
        let after = try #require(store.all().first)
        #expect(after.words == nil && after.rating == 0.8 && after.disputed == ["pace"])
        #expect(after.metrics == m)
    }

    @Test func undecryptableFilesArePurged() throws {
        let (store, dir) = try makeStore()
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).eqs"))
        #expect(try store.enforce(transcriptDays: 7) == 1)
    }

    @Test func voicePrintRoundTrip() throws {
        let (store, _) = try makeStore()
        #expect(store.loadVoicePrint() == nil)
        let v = VoicePrint(centroid: [0.6, 0.8], threshold: 0.45, created: .now)
        try store.saveVoicePrint(v)
        #expect(store.loadVoicePrint()?.centroid == v.centroid)
        store.deleteVoicePrint()
        #expect(store.loadVoicePrint() == nil)
    }
}
