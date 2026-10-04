import Foundation
import EventKit

/// Host-side calendar capability. The host owns the single `EKEventStore` and
/// the Calendar TCC permission; out-of-process plugins reach it only through
/// the `calendar/*` JSON-RPC methods on `HostBridge`. That keeps the
/// privileged surface in one audited place — a plugin (in any language) never
/// touches EventKit directly.
///
/// Replaces the per-feature `EKEventStore` instances that MeetingPrep and
/// BurnoutCopilot each held while they were in-host plugins.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    /// Whether full-access has been granted this session. Read-only to callers.
    private(set) var authorized = false

    /// Request EventKit full access. Idempotent — safe to call before every
    /// operation; once granted it's a cheap status check. macOS 14+ only
    /// (Halen's `LSMinimumSystemVersion`).
    @discardableResult
    func requestAccess() async -> Bool {
        if authorized { return true }
        do {
            authorized = try await store.requestFullAccessToEvents()
        } catch {
            authorized = false
            Log.warn("CalendarService: access request failed — \(error.localizedDescription)")
        }
        return authorized
    }

    /// Upcoming non-all-day events within the next `hours`, soonest first,
    /// capped at `max`. Returns an empty array (not an error) when access
    /// hasn't been granted — the caller decides how to surface that.
    func upcomingEvents(withinHours hours: Double, max: Int) -> [CalendarEvent] {
        guard authorized else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(hours * 3600),
            calendars: store.calendars(for: .event)
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .prefix(Swift.max(0, max))
            .map(CalendarEvent.init(from:))
    }

    /// Create an event in the user's default calendar. Returns the new
    /// event's identifier, or `nil` if access is missing / the save failed.
    func createEvent(title: String, start: Date, durationMinutes: Int) -> String? {
        guard authorized, let calendar = store.defaultCalendarForNewEvents else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(durationMinutes) * 60)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            Log.warn("CalendarService: createEvent failed — \(error.localizedDescription)")
            return nil
        }
    }
}

/// Serialisable view of one calendar event — the shape sent over JSON-RPC.
/// Deliberately flat and primitive so it maps cleanly to an `RPCValue.object`.
struct CalendarEvent {
    /// Per-*occurrence* id. `EKEvent.eventIdentifier` is shared across every
    /// instance of a recurring event, so it's combined with the start time —
    /// the same keying MeetingPrep used to dedupe briefings.
    let id: String
    let title: String
    let startEpoch: Double
    let endEpoch: Double
    let attendees: [String]
    let notes: String

    init(from event: EKEvent) {
        let start = event.startDate ?? Date()
        let base = event.eventIdentifier ?? UUID().uuidString
        self.id = "\(base)@\(Int(start.timeIntervalSince1970))"
        self.title = event.title ?? "Untitled"
        self.startEpoch = start.timeIntervalSince1970
        self.endEpoch = (event.endDate ?? start).timeIntervalSince1970
        self.attendees = (event.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        self.notes = event.notes ?? ""
    }

    /// JSON-RPC representation. `start`/`end` are Unix epoch seconds.
    var rpcObject: RPCValue {
        .object([
            "id": id,
            "title": title,
            "start": startEpoch,
            "end": endEpoch,
            "attendees": RPCValue.array(attendees.map(RPCValue.string)),
            "notes": notes,
        ] as [String: Any?])
    }
}
