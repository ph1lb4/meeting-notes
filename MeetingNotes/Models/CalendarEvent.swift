import Foundation

/// One person invited to a calendar event.
struct CalendarAttendee: Codable, Hashable {
    var name: String
    var email: String?
    var isOrganizer = false
    /// The owner of this Mac's calendar account.
    var isMe = false
}

/// A calendar event a meeting belongs to. Copied from EventKit, so it stays readable without calendar access.
struct CalendarEvent: Codable, Hashable, Identifiable {
    /// EventKit `calendarItemIdentifier`. Local to this Mac.
    var itemID: String
    var title: String
    var start: Date
    var end: Date
    var calendarName: String?
    var isRecurring = false
    /// Zoom, Meet, Teams, … link found in the event.
    var joinURL: URL?
    var attendees: [CalendarAttendee] = []

    /// Same event on another day is a different occurrence.
    var id: String { "\(itemID)@\(Int(start.timeIntervalSince1970))" }

    /// Everyone except the user.
    var others: [CalendarAttendee] { attendees.filter { !$0.isMe } }

    /// Opens the event in Calendar.app. Recurring events need the occurrence date in UTC.
    var calendarURL: URL? {
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: ":")).subtracting(CharacterSet(charactersIn: "/"))
        let id = itemID.addingPercentEncoding(withAllowedCharacters: allowed) ?? itemID
        if isRecurring {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return URL(string: "ical://ekevent/\(f.string(from: start))/\(id)?method=show&options=more")
        }
        return URL(string: "ical://ekevent/\(id)?method=show&options=more")
    }

    /// The event that a recording starting at `now` most likely belongs to: running now or starting within
    /// `lead` seconds. Events with a call link or other attendees win over blockers, then the closest start.
    static func current(in events: [CalendarEvent], at now: Date, lead: TimeInterval = 5 * 60) -> CalendarEvent? {
        let candidates = events.filter { $0.start.addingTimeInterval(-lead) <= now && now < $0.end }
        return candidates.min { a, b in
            if a.isCall != b.isCall { return a.isCall }
            return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
        }
    }

    /// Looks like a meeting with other people, not a focus block.
    var isCall: Bool { joinURL != nil || !others.isEmpty }

    /// Events worth a "join and transcribe" reminder at `now`: from `lead` seconds before the start
    /// until 5 minutes after it.
    static func dueReminders(in events: [CalendarEvent], at now: Date, lead: TimeInterval) -> [CalendarEvent] {
        events.filter { $0.isCall && $0.start.addingTimeInterval(-lead) <= now && now < $0.start.addingTimeInterval(5 * 60) }
            .sorted { $0.start < $1.start }
    }
}

extension CalendarEvent {
    /// Email addresses of everyone except the user, without duplicates.
    var otherEmails: [String] {
        var seen = Set<String>()
        return others.compactMap(\.email).filter { seen.insert($0.lowercased()).inserted }
    }

    /// A `mailto:` link that opens a draft in the default mail app.
    static func mailURL(to recipients: [String], subject: String, body: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = recipients.joined(separator: ",")
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // URLComponents leaves these as they are, but mail apps read them as separators.
        c.percentEncodedQuery = c.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }
}

/// Finds video call links in event fields.
enum MeetingLink {
    private static let hosts = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "around.co", "facetime.apple.com", "meet.jit.si", "gotomeeting.com", "chime.aws",
        "app.slack.com", "discord.gg", "discord.com",
    ]

    /// First link to a known call service, checked in field order (URL, location, notes).
    static func find(in fields: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for field in fields.compactMap({ $0 }) where !field.isEmpty {
            let range = NSRange(field.startIndex..., in: field)
            for match in detector.matches(in: field, range: range) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}
