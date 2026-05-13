import Foundation
import EventKit

/// Signal A: rolling 2-hour distraction-app focus time. Records per-app windows
/// from `app.focused` events and accumulates totals within `windowSeconds`.
@MainActor
final class DistractionTimeTracker {
    static let distractionBundles: Set<String> = [
        "com.tinyspeck.slackmacgap",       // Slack
        "com.hnc.Discord",                 // Discord
        "com.twitter.twitter-mac",         // Twitter classic
        "com.atebits.Tweetie2",            // Twitterrific
        "ru.keepcoder.Telegram",           // Telegram
        "com.reddit.reddit",
        "com.zhiliaoapp.musically",        // TikTok
        "com.facebook.archon",             // FB / Messenger
        "com.colliderli.iina",             // streaming
        "com.netflix.Netflix",
    ]

    struct FocusSegment {
        let bundleId: String
        let start: Date
        var end: Date
    }

    private var segments: [FocusSegment] = []
    private var currentBundleId: String?
    private var currentStart: Date?
    private let windowSeconds: TimeInterval = 2 * 60 * 60

    func note(focused bundleId: String, at now: Date = Date()) {
        // Close out previous segment if any.
        if let prev = currentBundleId, let start = currentStart {
            segments.append(FocusSegment(bundleId: prev, start: start, end: now))
        }
        currentBundleId = bundleId
        currentStart = now
        prune(now: now)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        segments.removeAll { $0.end < cutoff }
    }

    /// Total seconds spent in distraction apps in the last 2 hours.
    func distractionSecondsInWindow(now: Date = Date()) -> TimeInterval {
        prune(now: now)
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var total: TimeInterval = 0
        for seg in segments where Self.distractionBundles.contains(seg.bundleId) {
            let start = max(seg.start, cutoff)
            let end = min(seg.end, now)
            total += max(0, end.timeIntervalSince(start))
        }
        // Plus the ongoing segment, if it's a distraction app.
        if let cur = currentBundleId,
           let start = currentStart,
           Self.distractionBundles.contains(cur) {
            let s = max(start, cutoff)
            total += max(0, now.timeIntervalSince(s))
        }
        return total
    }

    var distractionMinutesInWindow: Int {
        Int(distractionSecondsInWindow() / 60)
    }
}

/// Signal B: rolling window of the last N tone classifications.
@MainActor
final class ToneTrendTracker {
    enum Tone { case calm, sharp }

    private(set) var window: [Tone] = []
    private let capacity = 10
    private let sharpThreshold = 3

    func record(_ tone: Tone) {
        window.append(tone)
        if window.count > capacity {
            window.removeFirst(window.count - capacity)
        }
    }

    var sharpCount: Int { window.filter { $0 == .sharp }.count }
    var trips: Bool { sharpCount >= sharpThreshold }
}

/// Signal C: calendar density via EventKit. Counts events in the next 4 hours
/// and detects back-to-back meetings within the next 30 minutes.
@MainActor
final class CalendarDensityTracker {
    private let store = EKEventStore()
    private(set) var hasAccess = false

    func requestAccess() async {
        do {
            if #available(macOS 14.0, *) {
                hasAccess = try await store.requestFullAccessToEvents()
            } else {
                hasAccess = try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { granted, error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume(returning: granted) }
                    }
                }
            }
            Log.info("BurnoutCopilot: calendar access = \(hasAccess)")
        } catch {
            hasAccess = false
            Log.warn("BurnoutCopilot: calendar access failed: \(error.localizedDescription)")
        }
    }

    struct Density: Equatable {
        let nextFourHourEvents: Int
        let hasBackToBackSoon: Bool
        let nextEventTitle: String?
        let nextEventStart: Date?
    }

    func snapshot(now: Date = Date()) -> Density {
        guard hasAccess else {
            return Density(nextFourHourEvents: 0, hasBackToBackSoon: false, nextEventTitle: nil, nextEventStart: nil)
        }
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(4 * 60 * 60),
            calendars: calendars
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        // Back-to-back within next 30min: an event starts within 30min, and the gap
        // between any two consecutive events (within that window) is < 5min.
        var backToBack = false
        let soonCutoff = now.addingTimeInterval(30 * 60)
        let soon = events.filter { ($0.startDate ?? .distantFuture) < soonCutoff }
        for i in 1..<max(1, soon.count) {
            let prev = soon[i - 1]
            let curr = soon[i]
            if let prevEnd = prev.endDate, let currStart = curr.startDate,
               currStart.timeIntervalSince(prevEnd) < 5 * 60 {
                backToBack = true
                break
            }
        }

        return Density(
            nextFourHourEvents: events.count,
            hasBackToBackSoon: backToBack,
            nextEventTitle: events.first?.title,
            nextEventStart: events.first?.startDate
        )
    }

    /// Convenience: create a 10-min "Halen break" event starting now in the default
    /// calendar. Returns true on success.
    func createBreakEvent(now: Date = Date()) -> Bool {
        guard hasAccess, let calendar = store.defaultCalendarForNewEvents else { return false }
        let ev = EKEvent(eventStore: store)
        ev.calendar = calendar
        ev.title = "🌿 Halen break"
        ev.startDate = now
        ev.endDate = now.addingTimeInterval(10 * 60)
        do {
            try store.save(ev, span: .thisEvent, commit: true)
            return true
        } catch {
            Log.warn("BurnoutCopilot: failed to create break event: \(error.localizedDescription)")
            return false
        }
    }
}
