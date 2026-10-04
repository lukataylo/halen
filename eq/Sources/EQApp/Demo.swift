#if DEBUG
import EQCore
import Foundation

/// Sample conversations for `EQ_DEMO=1` (screenshots, design iteration).
enum Demo {
    static func seed(_ store: SessionStore?) {
        guard let store else { return }
        let apps = ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.tinyspeck.slackmacgap"]
        var rng = SystemRandomNumberGenerator()
        for i in 0 ..< 14 {
            let hoursAgo = Double(i) * 11 + 0.3
            let windows = (0 ..< 60).map { w in
                WindowSummary(start: Double(w) * 5, speaking: Double.random(in: 0.2 ... 1, using: &rng),
                              pitchSt: Float.random(in: 7 ... (w > 40 && i % 3 == 0 ? 14 : 10), using: &rng),
                              db: Float.random(in: -32 ... (w > 40 && i % 3 == 0 ? -18 : -28), using: &rng),
                              wpm: Double.random(in: 120 ... 190, using: &rng))
            }
            var m = MetricsBuilder.build(frames: [], words: [], other: nil, duration: Double.random(in: 900 ... 2700, using: &rng))
            m.speakingSeconds = Double.random(in: 300 ... 900, using: &rng)
            m.wpm = Double.random(in: 125 ... 195, using: &rng)
            m.fillersPer100 = Double.random(in: 1 ... 9, using: &rng)
            m.pitchSdSt = Float.random(in: 1.6 ... 4, using: &rng)
            m.longestTurn = Double.random(in: 30 ... 200, using: &rng)
            m.turnsOver90s = Int.random(in: 0 ... 3, using: &rng)
            m.windows = windows
            m.talkRatio = Double.random(in: 0.3 ... 0.75, using: &rng)
            m.interruptionsPer10Min = Double.random(in: 0 ... 3, using: &rng)
            m.tone = Double.random(in: -0.4 ... 0.6, using: &rng)
            m.laughs = Int.random(in: 0 ... 5, using: &rng)
            m.voiceChecked = true
            m.ignoredSeconds = Double.random(in: 0 ... 40, using: &rng)
            var r = SessionRecord(startedAt: .now.addingTimeInterval(-hoursAgo * 3600), source: apps[i % apps.count],
                                  metrics: m, scores: ScoreCard(metrics: m, baseline: Baseline()), words: nil)
            r.takeaway = ["You gave people room to talk — your talk share stayed close to half. Next time: keep pausing before you answer.",
                          "You sped up noticeably in the last ten minutes. Next time: take one breath before each answer.",
                          "Two long stretches ran past 90 seconds. Next time: stop after your main point and ask a question."][i % 3]
            if i > 0 { r.rating = Double.random(in: 0 ... 1, using: &rng) }
            try? store.save(r)
        }
    }
}
#endif
