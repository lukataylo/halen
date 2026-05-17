import AppKit
import SwiftUI
import EventKit
import UserNotifications

/// 13–17 minutes before each upcoming calendar event, sends event metadata to
/// Gemma 4 E4B for a 5-bullet briefing, copies the result to the clipboard, and
/// posts a user notification. Processed event IDs are persisted so each event
/// is briefed exactly once.
@MainActor
final class MeetingPrep: HalenPlugin {
    let id = "com.halen.meeting-prep"
    let name = "Meeting Prep"
    let summary = "Fifteen minutes before a meeting, drops a briefing on your clipboard."
    let icon = "calendar.badge.clock"
    let category: PluginCategory = .scheduling

    private let services: HalenServices
    private let store = EKEventStore()
    private var pollTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    let state = MeetingPrepState()

    /// Keys of occurrences already briefed. Keyed per-occurrence (event id +
    /// start time), not raw `eventIdentifier` — that's shared across all
    /// instances of a recurring event, so briefing one would suppress them all.
    private var processedIds: Set<String> = []
    private var processedURL: URL { services.storageDirectory(for: id).appending(path: "processed.json") }

    init(services: HalenServices) {
        self.services = services
        loadProcessed()
    }

    func start() {
        guard pollTask == nil else { return }
        setupTask = Task { @MainActor [weak self] in
            await self?.requestPermissions()
            guard !Task.isCancelled else { return }
            self?.refreshNextEvent()
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollAndBrief()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
        Log.info("MeetingPrep started")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        setupTask?.cancel()
        setupTask = nil
    }

    func makeDetailView() -> AnyView {
        AnyView(MeetingPrepDetailView(
            state: state,
            onGenerateNow: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.generateNow()
                }
            },
            onRequestAccess: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.requestPermissions()
                    self?.refreshNextEvent()
                }
            }
        ))
    }

    // MARK: - Permissions

    private func requestPermissions() async {
        do {
            if #available(macOS 14.0, *) {
                state.calendarAuthorized = try await store.requestFullAccessToEvents()
            } else {
                state.calendarAuthorized = try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { ok, err in
                        if let err { cont.resume(throwing: err) } else { cont.resume(returning: ok) }
                    }
                }
            }
        } catch {
            state.calendarAuthorized = false
            Log.warn("MeetingPrep: calendar access failed: \(error.localizedDescription)")
        }

        do {
            try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            state.notificationsAuthorized = settings.authorizationStatus == .authorized
        } catch {
            state.notificationsAuthorized = false
            Log.warn("MeetingPrep: notification permission failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Polling + briefing

    private func pollAndBrief() async {
        guard state.calendarAuthorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(60 * 60),
            calendars: store.calendars(for: .event)
        )
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        refreshNextEvent(upcoming: upcoming)

        for event in upcoming {
            guard let start = event.startDate else { continue }
            let minutesAway = start.timeIntervalSince(now) / 60
            guard minutesAway >= 13, minutesAway <= 17 else { continue }
            guard let key = occurrenceKey(for: event), !processedIds.contains(key) else { continue }
            await brief(event: event)
        }
    }

    /// Per-occurrence key: `eventIdentifier` alone is shared across every
    /// instance of a recurring event, so it must be combined with the start time.
    private func occurrenceKey(for event: EKEvent) -> String? {
        guard let id = event.eventIdentifier else { return nil }
        guard let start = event.startDate else { return id }
        return "\(id)@\(Int(start.timeIntervalSince1970))"
    }

    private func generateNow() async {
        guard state.calendarAuthorized else {
            state.generation = .error(message: "Calendar access required — grant it above.")
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(24 * 60 * 60),
            calendars: store.calendars(for: .event)
        )
        guard let next = store.events(matching: predicate)
            .filter({ !$0.isAllDay })
            .sorted(by: { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) })
            .first
        else {
            state.generation = .error(message: "No upcoming events in the next 24 hours.")
            return
        }
        state.generation = .generating(title: next.title ?? "Untitled")
        await brief(event: next)
    }

    private func brief(event: EKEvent) async {
        let title = event.title ?? "Untitled"
        let attendees = (event.attendees ?? [])
            .compactMap { $0.name }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let description = event.notes ?? ""

        let prompt = """
        Write a 5-bullet meeting briefing. Output only the bullets, no preamble or trailing text.
        Cover: what's likely on the agenda; suggested questions to ask; things to bring up; prep needed; tone cue.

        Meeting: \(title)
        Attendees: \(attendees.isEmpty ? "(none listed)" : attendees)
        Description: \(description.isEmpty ? "(none)" : description)
        """

        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 400, temperature: 0.4, taskKind: .generation)
        do {
            let response = try await services.inference.complete(request)
            let briefing = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !briefing.isEmpty else {
                state.generation = .error(message: "Gemma returned an empty briefing.")
                return
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(briefing, forType: .string)

            await postNotification(for: event, briefing: briefing)

            let entry = MeetingPrepState.Brief(
                title: title,
                body: briefing,
                timestamp: Date()
            )
            state.recentBriefings.insert(entry, at: 0)
            if state.recentBriefings.count > 3 { state.recentBriefings.removeLast() }
            state.generation = .success(title: title)

            // Mark this specific occurrence briefed — whether it came from the
            // poll or an explicit "Generate now" — so it isn't briefed twice.
            if let key = occurrenceKey(for: event) {
                processedIds.insert(key)
                saveProcessed()
            }
            Log.info("MeetingPrep: briefed \"\(title)\" (\(response.latencyMs)ms)")
        } catch {
            state.generation = .error(message: error.localizedDescription)
            Log.warn("MeetingPrep: brief failed: \(error.localizedDescription)")
        }
    }

    private func postNotification(for event: EKEvent, briefing: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Meeting prep: \(event.title ?? "")"
        content.body = String(briefing.prefix(240))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.debug("MeetingPrep: notification post failed: \(error.localizedDescription)")
        }
    }

    private func refreshNextEvent(upcoming: [EKEvent]? = nil) {
        let now = Date()
        let events: [EKEvent]
        if let upcoming {
            events = upcoming
        } else if state.calendarAuthorized {
            let predicate = store.predicateForEvents(
                withStart: now,
                end: now.addingTimeInterval(24 * 60 * 60),
                calendars: store.calendars(for: .event)
            )
            events = store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        } else {
            events = []
        }
        if let next = events.first {
            state.nextEventTitle = next.title
            state.nextEventStart = next.startDate
            state.nextEventAttendees = (next.attendees ?? [])
                .compactMap { $0.name }
                .filter { !$0.isEmpty }
        } else {
            state.nextEventTitle = nil
            state.nextEventStart = nil
            state.nextEventAttendees = []
        }
    }

    // MARK: - Persistence

    private func loadProcessed() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: processedURL.path) else { return }  // first launch
        do {
            let data = try Data(contentsOf: processedURL)
            let list = try JSONDecoder().decode([String].self, from: data)
            // Prune anything older than 24 h. Each key is "<eventId>@<unix>";
            // we never brief a past meeting, so old keys are dead weight that
            // would otherwise grow the file forever.
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
            processedIds = Set(list.filter { key in
                guard let atIdx = key.lastIndex(of: "@"),
                      let ts = Double(key[key.index(after: atIdx)...]) else {
                    // Malformed key — keep it (paranoid; better than re-briefing).
                    return true
                }
                return ts >= cutoff
            })
        } catch {
            // The file existed but couldn't be decoded — corruption (disk
            // error, partial write from a previous crash, manual edit gone
            // wrong). Re-briefing today's already-briefed meetings is the
            // worst case and self-heals through the day, so we start clean.
            // Move the corrupt file aside rather than silently overwriting —
            // it stays available for diagnosis without blocking re-creation
            // of a fresh `processed.json`.
            Log.warn("MeetingPrep: processed.json failed to decode (\(error.localizedDescription)); quarantining and starting clean")
            let backup = processedURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: processedURL, to: backup)
        }
    }

    private func saveProcessed() {
        do {
            let data = try JSONEncoder().encode(Array(processedIds))
            try FileManager.default.createDirectory(
                at: processedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: processedURL, options: .atomic)
        } catch {
            Log.warn("MeetingPrep: failed to persist processed ids: \(error.localizedDescription)")
        }
    }
}

@MainActor
@Observable
final class MeetingPrepState {
    struct Brief: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        let timestamp: Date
    }

    enum GenerationStatus: Equatable {
        case idle
        case generating(title: String)
        case success(title: String)
        case error(message: String)
    }

    var calendarAuthorized = false
    var notificationsAuthorized = false
    var nextEventTitle: String?
    var nextEventStart: Date?
    var nextEventAttendees: [String] = []
    var recentBriefings: [Brief] = []
    var generation: GenerationStatus = .idle
}
