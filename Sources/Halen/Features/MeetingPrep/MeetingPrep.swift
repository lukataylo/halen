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
    let state = MeetingPrepState()

    private var processedIds: Set<String> = []
    private var processedURL: URL { services.storageDirectory(for: id).appending(path: "processed.json") }

    init(services: HalenServices) {
        self.services = services
        loadProcessed()
    }

    func start() {
        guard pollTask == nil else { return }
        Task { @MainActor [weak self] in
            await self?.requestPermissions()
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
    }

    func makeDetailView() -> AnyView {
        AnyView(MeetingPrepDetailView(
            state: state,
            onGenerateNow: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.generateNow()
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
            guard !processedIds.contains(event.eventIdentifier ?? "") else { continue }
            await brief(event: event)
        }
    }

    private func generateNow() async {
        guard state.calendarAuthorized else { return }
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
        else { return }
        await brief(event: next, force: true)
    }

    private func brief(event: EKEvent, force: Bool = false) async {
        let attendees = (event.attendees ?? [])
            .compactMap { $0.name }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let description = event.notes ?? ""

        let prompt = """
        Write a 5-bullet meeting briefing. Output only the bullets, no preamble or trailing text.
        Cover: what's likely on the agenda; suggested questions to ask; things to bring up; prep needed; tone cue.

        Meeting: \(event.title ?? "Untitled")
        Attendees: \(attendees.isEmpty ? "(none listed)" : attendees)
        Description: \(description.isEmpty ? "(none)" : description)
        """

        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 400, temperature: 0.4)
        do {
            let response = try await services.inference.complete(request)
            let briefing = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !briefing.isEmpty else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(briefing, forType: .string)

            await postNotification(for: event, briefing: briefing)

            let entry = MeetingPrepState.Brief(
                title: event.title ?? "Untitled",
                body: briefing,
                timestamp: Date()
            )
            state.recentBriefings.insert(entry, at: 0)
            if state.recentBriefings.count > 3 { state.recentBriefings.removeLast() }

            if !force, let id = event.eventIdentifier {
                processedIds.insert(id)
                saveProcessed()
            }
            Log.info("MeetingPrep: briefed \"\(event.title ?? "?")\" (\(response.latencyMs)ms)")
        } catch {
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
        } else {
            state.nextEventTitle = nil
            state.nextEventStart = nil
        }
    }

    // MARK: - Persistence

    private func loadProcessed() {
        do {
            let data = try Data(contentsOf: processedURL)
            let list = try JSONDecoder().decode([String].self, from: data)
            processedIds = Set(list)
        } catch {
            // first launch
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

    var calendarAuthorized = false
    var notificationsAuthorized = false
    var nextEventTitle: String?
    var nextEventStart: Date?
    var recentBriefings: [Brief] = []
}
