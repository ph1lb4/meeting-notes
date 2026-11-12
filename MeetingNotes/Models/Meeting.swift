import Foundation

enum AudioSource: String, Codable {
    case mic
    case system
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Seconds since the recording started.
    var start: Double
    var end: Double
    /// Speaker key, e.g. "me", "them", "s1". Display names live in `Meeting.speakerNames`.
    var speaker: String
    var text: String
}

struct MeetingNote: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Seconds since the recording started.
    var time: Double
    var text: String
}

/// Where a meeting can be sent through the user's Claude Code MCP servers.
enum ExportTarget: String, Codable, CaseIterable, Identifiable {
    case notion, linear
    var id: String { rawValue }
    var label: String {
        switch self {
        case .notion: return "Notion"
        case .linear: return "Linear"
        }
    }
    /// Only links to these hosts are shown as clickable after an export.
    var hosts: [String] {
        switch self {
        case .notion: return ["notion.so", "notion.site", "notion.com"]
        case .linear: return ["linear.app"]
        }
    }
}

/// One finished export: where Claude says it stored the meeting.
struct ExportRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var target: ExportTarget
    var date: Date
    /// Claude's short answer, plain Markdown.
    var result: String
}

enum MeetingPhase: String, Codable {
    case recording
    case finalizing
    case done
}

struct Meeting: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var duration: Double = 0
    var phase: MeetingPhase = .recording
    var segments: [TranscriptSegment] = []
    var notes: [MeetingNote] = []
    /// Speaker key -> display name.
    var speakerNames: [String: String] = [:]
    /// Folder name inside the notes directory.
    var folderName: String
    var hasSummary = false
    var titleEdited = false
    /// Bumped each time the summary files are rewritten, so views know to reload them.
    var summaryRevision = 0
    /// Segment id -> text before Claude's cleanup, for lines Claude changed. Lets the user undo the fixes.
    var originalTexts: [String: String] = [:]
    /// Notion / Linear exports, oldest first.
    var exports: [ExportRecord] = []

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, phase, segments, notes, speakerNames, folderName
        case hasSummary, titleEdited, summaryRevision, originalTexts, exports
    }

    func displayName(for speaker: String) -> String {
        if let name = speakerNames[speaker], !name.isEmpty { return name }
        switch speaker {
        case "me": return "Mic"
        case "them": return "Call"
        default:
            if speaker.hasPrefix("s"), let n = Int(speaker.dropFirst()) { return "Speaker \(n)" }
            return speaker
        }
    }

    /// Speakers in order of first appearance.
    var speakerKeys: [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for s in segments where !seen.contains(s.speaker) {
            seen.insert(s.speaker)
            keys.append(s.speaker)
        }
        return keys
    }

    /// Puts back the text of every line Claude's cleanup changed.
    mutating func restoreOriginalTexts() {
        for i in segments.indices {
            if let text = originalTexts[segments[i].id.uuidString] { segments[i].text = text }
        }
        originalTexts = [:]
    }

    /// Fixes a diarization split: every line of `key` now belongs to `target`.
    /// The name of `key` is dropped, `target` keeps its own.
    mutating func mergeSpeaker(_ key: String, into target: String) {
        guard key != target else { return }
        for i in segments.indices where segments[i].speaker == key {
            segments[i].speaker = target
        }
        speakerNames[key] = nil
    }

    /// Transcript entries and notes merged by time.
    enum Entry: Identifiable, Hashable {
        case segment(TranscriptSegment)
        case note(MeetingNote)
        var id: UUID {
            switch self {
            case .segment(let s): return s.id
            case .note(let n): return n.id
            }
        }
        var time: Double {
            switch self {
            case .segment(let s): return s.start
            case .note(let n): return n.time
            }
        }
    }

    /// Linear merge. AppState keeps segments and notes sorted; unsorted input (old files) is sorted first.
    var timeline: [Entry] {
        let segs = segments.isSorted { $0.start } ? segments : segments.sorted { $0.start < $1.start }
        let nts = notes.isSorted { $0.time } ? notes : notes.sorted { $0.time < $1.time }
        var out: [Entry] = []
        out.reserveCapacity(segs.count + nts.count)
        var i = 0, j = 0
        while i < segs.count, j < nts.count {
            if nts[j].time < segs[i].start {
                out.append(.note(nts[j])); j += 1
            } else {
                out.append(.segment(segs[i])); i += 1
            }
        }
        while i < segs.count { out.append(.segment(segs[i])); i += 1 }
        while j < nts.count { out.append(.note(nts[j])); j += 1 }
        return out
    }

    /// True for diarized speaker keys (s1, s2, ...), false for "me" and "them".
    static func isDiarizedKey(_ key: String) -> Bool {
        key.hasPrefix("s") && Int(key.dropFirst()) != nil
    }
}

// In an extension so the memberwise initializer stays available.
extension Meeting {
    /// Tolerant decoding: fields added after 1.0 fall back to defaults so old meeting.json files load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        phase = try c.decodeIfPresent(MeetingPhase.self, forKey: .phase) ?? .done
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        notes = try c.decodeIfPresent([MeetingNote].self, forKey: .notes) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        hasSummary = try c.decodeIfPresent(Bool.self, forKey: .hasSummary) ?? false
        titleEdited = try c.decodeIfPresent(Bool.self, forKey: .titleEdited) ?? false
        summaryRevision = try c.decodeIfPresent(Int.self, forKey: .summaryRevision) ?? 0
        originalTexts = try c.decodeIfPresent([String: String].self, forKey: .originalTexts) ?? [:]
        exports = try c.decodeIfPresent([ExportRecord].self, forKey: .exports) ?? []
    }
}

private extension Array {
    func isSorted(by key: (Element) -> Double) -> Bool {
        var last = -Double.infinity
        for e in self {
            let k = key(e)
            if k < last { return false }
            last = k
        }
        return true
    }
}

extension Double {
    var timestamp: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
