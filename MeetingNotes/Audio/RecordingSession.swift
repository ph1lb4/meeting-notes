import Foundation

/// Runs mic + call audio capture for one meeting.
final class RecordingSession {
    let startDate = Date()
    let audioFolder: URL
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private(set) var micTrack: TrackRecorder!
    private(set) var systemTrack: TrackRecorder?
    private(set) var systemAudioError: String?

    var micURL: URL { audioFolder.appendingPathComponent("mic.caf") }
    var systemURL: URL { audioFolder.appendingPathComponent("system.caf") }

    init(audioFolder: URL) {
        self.audioFolder = audioFolder
    }

    func start(captureSystemAudio: Bool,
               onChunk: @escaping (AudioSource, [Float], Double) -> Void) throws {
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)

        micTrack = try TrackRecorder(source: .mic, fileURL: micURL, startDate: startDate) { onChunk(.mic, $0, $1) }
        mic.onSamples = { [weak self] in self?.micTrack.append($0) }
        try mic.start()

        if captureSystemAudio {
            do {
                let track = try TrackRecorder(source: .system, fileURL: systemURL, startDate: startDate) { onChunk(.system, $0, $1) }
                systemTrack = track
                system.onSamples = { track.append($0) }
                try system.start()
            } catch {
                systemTrack = nil
                systemAudioError = error.localizedDescription
                try? FileManager.default.removeItem(at: systemURL)
                NSLog("System audio capture failed: \(error)")
            }
        }
    }

    var duration: Double { Date().timeIntervalSince(startDate) }
    var micLevel: Float { micTrack?.level ?? 0 }
    var systemLevel: Float { systemTrack?.level ?? 0 }
    /// True if writing either audio file failed. Live chunks still flow, but the final pass may miss audio.
    var writeFailed: Bool { micTrack?.writeFailed == true || systemTrack?.writeFailed == true }

    func stop() {
        mic.stop()
        system.stop()
        micTrack?.finish()
        systemTrack?.finish()
    }
}
