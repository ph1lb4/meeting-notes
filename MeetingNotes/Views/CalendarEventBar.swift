import SwiftUI

/// Under the meeting title: the linked calendar event with its attendees, or a menu to link one.
struct CalendarEventBar: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        if let event = meeting.calendarEvent {
            HStack(spacing: 8) {
                Menu {
                    if let url = event.calendarURL {
                        Button("Open in Calendar") { NSWorkspace.shared.open(url) }
                    }
                    if let url = event.joinURL {
                        Button("Open Call Link") { NSWorkspace.shared.open(url) }
                    }
                    if !event.attendees.isEmpty {
                        Button("Copy Attendees") {
                            state.copyToClipboard(event.attendees.map { a in
                                a.email.map { "\(a.name) <\($0)>" } ?? a.name
                            }.joined(separator: "\n"))
                        }
                    }
                    Divider()
                    LinkEventMenu(meeting: meeting, title: "Link Another Event")
                    Button("Unlink Event") { state.linkEvent(nil, to: meeting.id) }
                } label: {
                    Label(event.title, systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("\(event.start.formatted(date: .abbreviated, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened))\(event.calendarName.map { " · \($0)" } ?? "")")

                if !event.attendees.isEmpty {
                    AttendeeList(attendees: event.attendees)
                }
            }
            .font(.callout)
        } else if state.calendar.isActive {
            LinkEventMenu(meeting: meeting, title: "Link Calendar Event")
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Events around the meeting's time. Fetched when the menu opens.
private struct LinkEventMenu: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let title: String

    var body: some View {
        Menu {
            let events = state.calendar.events(near: meeting)
            if events.isEmpty {
                Text("No events around this time")
            }
            ForEach(events) { event in
                Button("\(event.start.formatted(date: .omitted, time: .shortened))  \(event.title)") {
                    state.linkEvent(event, to: meeting.id)
                }
                .disabled(event.id == meeting.calendarEvent?.id)
            }
        } label: {
            Label(title, systemImage: "calendar.badge.plus")
        }
    }
}

private struct AttendeeList: View {
    let attendees: [CalendarAttendee]

    var body: some View {
        let shown = attendees.prefix(5)
        HStack(spacing: 4) {
            Image(systemName: "person.2").foregroundStyle(.secondary)
            Text(shown.map { $0.isMe ? "\($0.name) (you)" : $0.name }.joined(separator: ", ")
                 + (attendees.count > shown.count ? " +\(attendees.count - shown.count)" : ""))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(attendees.map { a in
            var line = a.name
            if let email = a.email, email != a.name { line += " <\(email)>" }
            if a.isOrganizer { line += " · organizer" }
            return line
        }.joined(separator: "\n"))
    }
}
