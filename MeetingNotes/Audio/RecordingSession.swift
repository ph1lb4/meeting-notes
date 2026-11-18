import Foundation

/// Runs mic + call audio capture for one meeting.
final class RecordingSession {
    private let startInstant = ContinuousClock.now
    private let backoff = RestartBackoff()
    let audioFolder: URL
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private(set) var micTrack: TrackRecorder!
    private(set) var systemTrack: TrackRecorder?
    /// Why call audio could not start. With a `systemTrack`, capture keeps trying.
    private(set) var systemAudioError: String?
    private var micWatch = StallWatchdog()
    private var systemWatch = StallWatchdog()

    var micURL: URL { audioFolder.appendingPathComponent("mic.caf") }
    var systemURL: URL { audioFolder.appendingPathComponent("system.caf") }

    init(audioFolder: URL) {
        self.audioFolder = audioFolder
    }

    func start(captureSystemAudio: Bool,
               onChunk: @escaping (AudioSource, [Float], Double) -> Void) throws {
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let start = startInstant
        let clock: TrackRecorder.Clock = { Self.seconds(since: start) }

        micTrack = try TrackRecorder(source: .mic, fileURL: micURL, clock: clock) { onChunk(.mic, $0, $1) }
        mic.onSamples = { [weak self] in self?.micTrack.append($0) }
        try mic.start()

        if captureSystemAudio {
            do {
                let track = try TrackRecorder(source: .system, fileURL: systemURL, clock: clock) { onChunk(.system, $0, $1) }
                systemTrack = track
                system.onSamples = { track.append($0) }
            } catch {
                systemAudioError = error.localizedDescription
                try? FileManager.default.removeItem(at: systemURL)
                NSLog("Creating the call audio file failed: \(error)")
                return
            }
            do {
                try system.start()
            } catch {
                // The track stays: capture keeps trying, and the track pads the time it missed.
                systemAudioError = error.localizedDescription
                NSLog("System audio capture failed, will keep trying: \(error)")
            }
        }
    }

    /// Restarts a track that delivers no audio although nothing reported an error.
    /// Call it a few times per second, always from the same thread.
    func checkStalls() {
        let now = duration
        if let micTrack, micWatch.update(silentFor: micTrack.silentFor, at: now) { mic.kick() }
        if let systemTrack, systemWatch.update(silentFor: systemTrack.silentFor, at: now) { system.kick() }
    }

    /// Seconds since the recording started. Counts time asleep, ignores changes of the system time.
    var duration: Double { Self.seconds(since: startInstant) }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let passed = (ContinuousClock.now - start).components
        return Double(passed.seconds) + Double(passed.attoseconds) * 1e-18
    }

    /// Set while a track is dead and its restarts keep failing. Nil again once it is back.
    var captureProblem: String? {
        if backoff.shouldWarn(afterFailures: mic.failedRestarts)
            || micTrack.map({ micWatch.shouldWarn(silentFor: $0.silentFor) }) == true {
            return "The microphone stopped working. Meeting Notes keeps trying to bring it back. Check the input device in System Settings > Sound."
        }
        // A failed start was already reported, so stay quiet until call audio worked once.
        if let systemTrack, systemAudioError == nil || systemTrack.hasAudio,
           backoff.shouldWarn(afterFailures: system.failedRestarts) || systemWatch.shouldWarn(silentFor: systemTrack.silentFor) {
            return "Call audio stopped working. Meeting Notes keeps trying to bring it back. Your microphone is still recorded."
        }
        return nil
    }
    var micLevel: Float { micTrack?.level ?? 0 }
    var systemLevel: Float { systemTrack?.level ?? 0 }
    /// True if writing either audio file failed. Live chunks still flow, but the final pass may miss audio.
    var writeFailed: Bool { micTrack?.writeFailed == true || systemTrack?.writeFailed == true }

    /// True once the call track got audio. False if call audio is off or never started.
    var hasSystemAudio: Bool { systemTrack?.hasAudio == true }
    /// True once the call track had a sound. Nil while call audio is off or did not start yet.
    var callAudioHeard: Bool? { hasSystemAudio ? systemTrack?.heardSound : nil }

    func stop() {
        mic.stop()
        system.stop()
        micTrack?.finish()
        systemTrack?.finish()
        // Call audio never started: leave no empty file for the final pass.
        if systemTrack != nil, !hasSystemAudio { try? FileManager.default.removeItem(at: systemURL) }
    }
}
