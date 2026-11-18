import SwiftUI

struct CalendarSettingsSection: View {
    @Environment(AppState.self) private var state

    @AppStorage(Prefs.Key.calendarEnabled) private var enabled = false
    @AppStorage(Prefs.Key.joinReminder) private var joinReminder = true
    @AppStorage(Prefs.Key.joinReminderLead) private var lead = 1

    var body: some View {
        Section("Calendar") {
            Toggle("Link recordings to calendar events", isOn: Binding(get: { enabled }, set: setEnabled))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.calendarSettingsChanged()
                }
            Text("A recording takes the title and attendees of the event running now. The calendar stays on this Mac. Attendee names go to Claude with the transcript.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled, state.calendar.access == .denied {
                HStack {
                    Text("Meeting Notes has no calendar access.")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Privacy Settings") { state.calendar.openPrivacySettings() }
                }
            }
            if enabled {
                Toggle("Remind me to join and transcribe", isOn: $joinReminder)
                    .onChange(of: joinReminder) { state.calendarSettingsChanged() }
                if joinReminder {
                    Picker("Show the reminder", selection: $lead) {
                        Text("When it starts").tag(0)
                        Text("1 min before").tag(1)
                        Text("2 min before").tag(2)
                        Text("5 min before").tag(5)
                    }
                    Text("For events with a call link or other attendees. One click joins the call and starts recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setEnabled(_ on: Bool) {
        if on {
            Task { _ = await state.enableCalendar() }
        } else {
            enabled = false
            state.calendarSettingsChanged()
        }
    }
}
