import Foundation
import SwiftUI

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto, de, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (German + English)"
        case .de: return "German"
        case .en: return "English"
        }
    }
}

/// Which engine the user wants for summaries.
enum SummaryEngineChoice: String, CaseIterable, Identifiable {
    case auto, claude, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .claude: return "Claude only"
        case .apple: return "Apple Intelligence only"
        }
    }
    var detail: String {
        switch self {
        case .auto: return "Uses Claude when Claude Code is installed, otherwise Apple Intelligence on this Mac."
        case .claude: return "Best summaries. The transcript is sent to Anthropic."
        case .apple: return "Runs fully on this Mac. Shorter, simpler summaries."
        }
    }
}

struct WhisperModelOption: Identifiable, Hashable {
    let id: String
    let label: String

    static let all: [WhisperModelOption] = [
        .init(id: "openai_whisper-large-v3-v20240930_turbo", label: "Large v3 Turbo (best, ~1.6 GB)"),
        .init(id: "openai_whisper-large-v3-v20240930_626MB", label: "Large v3 Turbo compressed (~630 MB)"),
        .init(id: "openai_whisper-small", label: "Small (fast, ~480 MB)"),
        .init(id: "openai_whisper-base", label: "Base (fastest, ~150 MB)"),
    ]
}

/// Thin wrapper around UserDefaults so non-UI code can read settings too.
enum Prefs {
    static let defaults = UserDefaults.standard

    enum Key {
        static let model = "whisperModel"
        static let language = "language"
        static let keepAudio = "keepAudio"
        static let autoSummarize = "autoSummarize"
        static let notesFolder = "notesFolder"
        static let claudePath = "claudePath"
        static let claudeModel = "claudeModel"
        static let captureSystemAudio = "captureSystemAudio"
        static let summaryEngine = "summaryEngine"
        /// Core Audio UID of the chosen microphone. Empty means system default.
        static let micDeviceUID = "micDeviceUID"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.model: WhisperModelOption.all[0].id,
            Key.language: TranscriptionLanguage.auto.rawValue,
            Key.keepAudio: false,
            Key.autoSummarize: true,
            Key.claudePath: "",
            Key.claudeModel: "",
            Key.captureSystemAudio: true,
            Key.summaryEngine: SummaryEngineChoice.auto.rawValue,
            Key.micDeviceUID: "",
        ])
    }

    static var model: String { defaults.string(forKey: Key.model) ?? WhisperModelOption.all[0].id }
    static var language: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto
    }
    static var keepAudio: Bool { defaults.bool(forKey: Key.keepAudio) }
    static var autoSummarize: Bool { defaults.bool(forKey: Key.autoSummarize) }
    static var captureSystemAudio: Bool { defaults.bool(forKey: Key.captureSystemAudio) }
    static var micDeviceUID: String { defaults.string(forKey: Key.micDeviceUID) ?? "" }
    static var claudePath: String { defaults.string(forKey: Key.claudePath) ?? "" }
    static var claudeModel: String { defaults.string(forKey: Key.claudeModel) ?? "" }
    static var summaryEngine: SummaryEngineChoice {
        SummaryEngineChoice(rawValue: defaults.string(forKey: Key.summaryEngine) ?? "") ?? .auto
    }

    static func whisperModelFolder(_ id: String) -> URL {
        modelsFolder.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)", isDirectory: true)
    }

    static func isWhisperModelDownloaded(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: whisperModelFolder(id).appendingPathComponent("config.json").path)
    }

    static var notesFolder: URL {
        if let path = defaults.string(forKey: Key.notesFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Notes", isDirectory: true)
    }

    /// Audio is recorded here, outside the (often iCloud synced) notes folder.
    static var recordingsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingNotes/Recordings", isDirectory: true)
    }

    static var modelsFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingNotes/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
