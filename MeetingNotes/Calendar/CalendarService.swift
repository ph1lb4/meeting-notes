import AppKit
import EventKit
import Observation

/// Reads events from the calendars on this Mac (iCloud, Google, Exchange, … as set up in Calendar.app).
/// The only type that imports EventKit. Nothing is read unless the user turned the calendar on.
@MainActor
@Observable
final class CalendarService {
    enum Access: Equatable {
        case notAsked, granted, denied
    }

    private(set) var access: Access = .notAsked
    /// Bumped when the calendar database changes, so views can fetch again.
    private(set) var revision = 0

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        refreshAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    /// True when the user turned the calendar on and macOS allows reading it.
    var isActive: Bool { Prefs.calendarEnabled && access == .granted }

    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notAsked
        default: access = .denied
        }
    }

    /// Asks macOS for calendar access. Returns true when it was given.
    @discardableResult
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { store.reset() }
        refreshAccess()
        return granted
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Timed events in the range, without all-day, cancelled and declined ones. Sorted by start.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard isActive else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .map(Self.convert)
            .sorted { $0.start < $1.start }
    }

    /// The event running now or starting in the next few minutes, if any.
    func currentEvent(at now: Date = Date()) -> CalendarEvent? {
        CalendarEvent.current(in: events(from: now.addingTimeInterval(-12 * 3600), to: now.addingTimeInterval(3600)), at: now)
    }

    /// Events around a meeting, for linking it by hand.
    func events(near meeting: Meeting) -> [CalendarEvent] {
        let end = meeting.createdAt.addingTimeInterval(max(meeting.duration, 60))
        return events(from: meeting.createdAt.addingTimeInterval(-3 * 3600), to: end.addingTimeInterval(3 * 3600))
    }

    // MARK: - Mapping

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent {
        var people: [CalendarAttendee] = []
        var seen = Set<String>()
        func add(_ p: EKParticipant, organizer: Bool) {
            guard p.participantType != .room, p.participantType != .resource else { return }
            let email = p.url.scheme == "mailto" ? String(p.url.absoluteString.dropFirst("mailto:".count)).removingPercentEncoding : nil
            let key = (email ?? p.name ?? p.url.absoluteString).lowercased()
            // The organizer comes first and is usually in the attendee list too.
            guard seen.insert(key).inserted else { return }
            let name = p.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? email ?? "Unknown"
            people.append(CalendarAttendee(name: name, email: email, isOrganizer: organizer, isMe: p.isCurrentUser))
        }
        if let organizer = event.organizer { add(organizer, organizer: true) }
        for p in event.attendees ?? [] { add(p, organizer: false) }

        return CalendarEvent(
            itemID: event.calendarItemIdentifier,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            calendarName: event.calendar?.title,
            isRecurring: event.hasRecurrenceRules,
            joinURL: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
            attendees: people
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
