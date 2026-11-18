import AppKit
import SwiftUI

/// Shows a small floating panel shortly before a calendar call, with "Join & Transcribe".
/// Checks the calendar every 15 seconds while the calendar and the reminder are on.
@MainActor
final class JoinReminder {
    private let calendar: CalendarService
    /// Join the call (if `join`) and start recording for the event.
    private let start: (CalendarEvent, _ join: Bool) -> Void
    private let isRecording: () -> Bool

    private var timer: Timer?
    private var panel: NSPanel?
    private var shownEvent: CalendarEvent?
    /// Occurrences already shown (or dismissed), so each one pops up once.
    private var handled = Set<String>()

    init(calendar: CalendarService, isRecording: @escaping () -> Bool,
         start: @escaping (CalendarEvent, _ join: Bool) -> Void) {
        self.calendar = calendar
        self.isRecording = isRecording
        self.start = start
    }

    /// Starts or stops the timer to match the settings. Call after the settings or calendar access change.
    func update() {
        let on = calendar.isActive && Prefs.joinReminder
        if on, timer == nil {
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            check()
        } else if !on {
            timer?.invalidate()
            timer = nil
            close()
        }
    }

    private func check() {
        let now = Date()
        // A shown reminder goes away 5 minutes after the start, or when recording starts for it.
        if let shown = shownEvent, now >= shown.start.addingTimeInterval(5 * 60) { close() }
        guard panel == nil else { return }
        let lead = TimeInterval(Prefs.joinReminderLead * 60)
        let events = calendar.events(from: now.addingTimeInterval(-10 * 60), to: now.addingTimeInterval(lead + 60))
        guard let event = CalendarEvent.dueReminders(in: events, at: now, lead: lead)
            .first(where: { !handled.contains($0.id) }) else { return }
        handled.insert(event.id)
        show(event)
    }

    /// Hides the panel, e.g. once a recording started some other way.
    func close() {
        panel?.orderOut(nil)
        panel = nil
        shownEvent = nil
    }

    private func show(_ event: CalendarEvent) {
        let view = JoinReminderView(
            event: event,
            busy: isRecording(),
            onJoin: { [weak self] in self?.close(); self?.start(event, true) },
            onRecord: { [weak self] in self?.close(); self?.start(event, false) },
            onJoinOnly: { [weak self] in
                self?.close()
                if let url = event.joinURL { NSWorkspace.shared.open(url) }
            },
            onDismiss: { [weak self] in self?.close() }
        )
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - host.fittingSize.width - 16,
                                         y: screen.maxY - host.fittingSize.height - 16))
        }
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
        self.panel = panel
        shownEvent = event
    }
}

private struct JoinReminderView: View {
    let event: CalendarEvent
    /// Another meeting is recording. Only joining is offered then.
    let busy: Bool
    let onJoin: () -> Void
    let onRecord: () -> Void
    let onJoinOnly: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.headline).lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(startText(now: context.date)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            }
            if !event.others.isEmpty {
                Text(event.others.map(\.name).prefix(4).joined(separator: ", ")
                     + (event.others.count > 4 ? " +\(event.others.count - 4)" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                if busy {
                    Text("Still recording another meeting.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if event.joinURL != nil {
                        Button("Join", action: onJoinOnly).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Spacer()
                    if event.joinURL != nil {
                        Button("Transcribe Only", action: onRecord)
                        Button("Join & Transcribe", action: onJoin).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Transcribe", action: onRecord).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private func startText(now: Date) -> String {
        let seconds = event.start.timeIntervalSince(now)
        let time = event.start.formatted(date: .omitted, time: .shortened)
        if seconds > 50 { return "Starts in \(Int((seconds / 60).rounded())) min · \(time)" }
        if seconds > -60 { return "Starts now · \(time)" }
        return "Started \(Int((-seconds / 60).rounded())) min ago · \(time)"
    }
}
