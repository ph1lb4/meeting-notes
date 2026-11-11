import Foundation

/// Reads and writes meetings as folders of Markdown files plus a small meeting.json.
/// Pure file helpers. AppState decides when they run and on which queue.
enum MeetingStore {
    static let jsonName = "meeting.json"
    static let transcriptName = "transcript.md"
    static let summaryName = "summary.md"
    static let actionItemsName = "action-items.md"
    static let audioFolderName = "audio"
    static let micFileName = "mic.caf"
    static let systemFileName = "system.caf"

    private static var fm: FileManager { .default }

    // MARK: - Paths

    static func folder(for meeting: Meeting) -> URL {
        Prefs.notesFolder.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    /// Kept audio ("Keep audio" on) lives inside the meeting folder.
    static func audioFolder(for meeting: Meeting) -> URL {
        folder(for: meeting).appendingPathComponent(audioFolderName, isDirectory: true)
    }

    /// Audio is recorded here, outside the notes folder, so it never syncs to iCloud.
    static func recordingFolder(for id: UUID) -> URL {
        Prefs.recordingsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Folder that holds this meeting's audio, if any. The recordings folder wins over kept audio.
    static func audioSource(for meeting: Meeting) -> URL? {
        [recordingFolder(for: meeting.id), audioFolder(for: meeting)].first {
            fm.fileExists(atPath: $0.appendingPathComponent(micFileName).path)
        }
    }

    static func makeFolderName(date: Date, title: String, current: String? = nil) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(f.string(from: date)) \(safe.isEmpty ? "Meeting" : String(safe.prefix(60)))"
        var name = base
        var i = 2
        while name != current, fm.fileExists(atPath: Prefs.notesFolder.appendingPathComponent(name).path) {
            name = "\(base) \(i)"
            i += 1
        }
        return name
    }

    // MARK: - Meetings

    /// Decodes every meeting in `root`. Returns nil if the folder cannot be read. Safe to call off the main thread.
    static func loadAll(in root: URL) -> [Meeting]? {
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir -> Meeting? in
            let url = dir.appendingPathComponent(jsonName)
            guard let data = try? Data(contentsOf: url),
                  var m = try? decoder.decode(Meeting.self, from: data) else { return nil }
            m.folderName = dir.lastPathComponent
            return m
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Writes meeting.json and transcript.md into `dir`.
    static func save(_ meeting: Meeting, to dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meeting).write(to: dir.appendingPathComponent(jsonName), options: .atomic)
        try MarkdownExporter.transcript(for: meeting)
            .write(to: dir.appendingPathComponent(transcriptName), atomically: true, encoding: .utf8)
    }

    static func read(_ name: String, of meeting: Meeting) -> String? {
        try? String(contentsOf: folder(for: meeting).appendingPathComponent(name), encoding: .utf8)
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Moves a meeting folder (rename).
    static func move(_ from: URL, to: URL) throws {
        try fm.moveItem(at: from, to: to)
    }

    /// Moves the meeting folder to the Trash and removes its recordings.
    static func delete(folder: URL, recording: URL) {
        try? fm.trashItem(at: folder, resultingItemURL: nil)
        try? fm.removeItem(at: recording)
    }

    // MARK: - Audio

    /// Moves recorded audio into the meeting folder ("Keep audio"). No-op if there is no recording.
    static func keepAudio(from recording: URL, to kept: URL) throws {
        guard let files = try? fm.contentsOfDirectory(at: recording, includingPropertiesForKeys: nil) else { return }
        try fm.createDirectory(at: kept, withIntermediateDirectories: true)
        for file in files {
            let target = kept.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: file, to: target)
        }
        try? fm.removeItem(at: recording)
    }

    static func deleteAudio(recording: URL, kept: URL) {
        try? fm.removeItem(at: recording)
        try? fm.removeItem(at: kept)
    }

    /// Recordings folders whose meeting is not in `ids`.
    static func orphanRecordings(keeping ids: Set<UUID>) -> [URL] {
        let dirs = (try? fm.contentsOfDirectory(at: Prefs.recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return false }
            return !ids.contains(id)
        }
    }

    static func remove(_ urls: [URL]) {
        for url in urls { try? fm.removeItem(at: url) }
    }
}
