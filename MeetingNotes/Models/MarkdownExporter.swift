import Foundation

/// Produces plain Markdown that pastes cleanly into Notion (headings, bold, bullets, to-dos).
enum MarkdownExporter {
    static func header(for meeting: Meeting) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        let people = meeting.speakerKeys.map { meeting.displayName(for: $0) }.joined(separator: ", ")
        var lines = ["**Date:** \(f.string(from: meeting.createdAt))", "**Duration:** \(minutes) min"]
        if !people.isEmpty { lines.append("**Speakers:** \(people)") }
        return lines.joined(separator: "  \n")
    }

    static func notes(for meeting: Meeting) -> String {
        meeting.notes.map { "- [\($0.time.timestamp)] \($0.text)" }.joined(separator: "\n")
    }

    /// Transcript body with consecutive lines from the same speaker merged.
    static func transcriptBody(for meeting: Meeting) -> String {
        var blocks: [String] = []
        var current: (speaker: String, start: Double, text: [String])?
        for seg in meeting.segments.sorted(by: { $0.start < $1.start }) {
            if let c = current, c.speaker == seg.speaker {
                current?.text.append(seg.text)
            } else {
                if let c = current {
                    blocks.append("**[\(c.start.timestamp)] \(meeting.displayName(for: c.speaker)):** \(c.text.joined(separator: " "))")
                }
                current = (seg.speaker, seg.start, [seg.text])
            }
        }
        if let c = current {
            blocks.append("**[\(c.start.timestamp)] \(meeting.displayName(for: c.speaker)):** \(c.text.joined(separator: " "))")
        }
        return blocks.joined(separator: "\n\n")
    }

    static func transcript(for meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n\(header(for: meeting))\n"
        if !meeting.notes.isEmpty {
            out += "\n## My notes\n\n\(notes(for: meeting))\n"
        }
        out += "\n## Transcript\n\n\(transcriptBody(for: meeting))\n"
        return out
    }
}
