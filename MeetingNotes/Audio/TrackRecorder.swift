import AVFoundation
import os

/// One audio track (mic or system). Writes 16 kHz audio to disk, keeps it aligned to the
/// wall clock, and cuts speech into chunks for live transcription using a simple energy VAD.
final class TrackRecorder {
    typealias ChunkHandler = (_ samples: [Float], _ startTime: Double) -> Void
    /// Seconds since the recording started. Shared by both tracks so they stay aligned, and
    /// monotonic, so a change of the system time cannot shift the audio.
    typealias Clock = () -> Double

    let source: AudioSource
    let fileURL: URL
    private let clock: Clock
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private let onChunk: ChunkHandler

    private let rate = AudioConverter16k.sampleRate
    private let frameSize = 480 // 30 ms
    /// Samples on the track's timeline so far (audio plus padded silence).
    private var position: Int = 0
    /// Samples that could not be written. Filled with silence once writing works again,
    /// so audio after a failed write keeps its place in the file.
    private var unwritten: Int = 0
    /// Sample index of the next VAD frame.
    private var vadPos: Int = 0

    // VAD state
    private var pending: [Float] = []
    private var pendingStart: Int = 0
    private var frameRemainder: [Float] = []
    private var speechFrames = 0
    private var trailingSilence = 0
    private var noiseFloor: Float = 0.002
    /// Frames in a row above the speech threshold, and the quietest of them.
    private var loudRun = 0
    private var loudMin = Float.infinity
    /// Three seconds of frames. Speech dips below the threshold between words, steady noise does not.
    private let steadyNoiseFrames = 100
    /// Less speech than this in a chunk is a click, not a word.
    private let minSpeech = 0.2
    /// Silence for padding, written piece by piece so a long gap (the Mac slept) needs no big buffer.
    private let silence: [Float]
    /// The meter falls to zero when no audio came in for this long (capture died or is restarting).
    private let staleAfter = 1.0

    private struct Stats {
        var level: Float = 0
        var lastAudio: Double = -.infinity
        var hasAudio = false
        var heardSound = false
        var writeFailed = false
    }
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    /// Last RMS level, for the UI meter. Zero once the track stopped delivering audio. Read from any thread.
    var level: Float {
        let now = clock()
        return stats.withLock { now - $0.lastAudio > staleAfter ? 0 : $0.level }
    }
    /// Seconds since the last audio arrived, counted from the start if none came yet.
    /// A running capture delivers all the time, also when it is quiet. Read from any thread.
    var silentFor: Double {
        let now = clock()
        return stats.withLock { now - max($0.lastAudio, 0) }
    }
    /// True once any audio arrived.
    var hasAudio: Bool { stats.withLock { $0.hasAudio } }
    /// True once a sample was not zero. A call track without the system audio permission stays at zero.
    var heardSound: Bool { stats.withLock { $0.heardSound } }
    /// True once a write to the audio file failed. Recording continues, but the file is incomplete.
    var writeFailed: Bool { stats.withLock { $0.writeFailed } }

    init(source: AudioSource, fileURL: URL, clock: @escaping Clock, onChunk: @escaping ChunkHandler) throws {
        self.source = source
        self.fileURL = fileURL
        self.clock = clock
        self.silence = [Float](repeating: 0, count: Int(AudioConverter16k.sampleRate))
        self.onChunk = onChunk
        self.queue = DispatchQueue(label: "TrackRecorder.\(source.rawValue)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        frameRemainder.reserveCapacity(frameSize)
        file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ samples: [Float]) {
        // Taken on arrival, not when the queue gets to it, so a busy queue cannot cause padding.
        let now = clock()
        queue.async { [self] in
            guard file != nil else { return }
            let first = position == 0
            let heard = stats.withLock { state -> Bool in
                state.lastAudio = now
                state.hasAudio = true
                return state.heardSound
            }
            if !heard, samples.contains(where: { $0 != 0 }) {
                stats.withLock { $0.heardSound = true }
            }
            // Pad silence if this track is behind the clock (late start, device gap).
            // The first audio is placed exactly, so both tracks start aligned. Later, small
            // jitter is left alone and only a real gap is filled.
            let expected = Int(now * rate) - samples.count
            var gap = expected - position
            if gap > (first ? 0 : Int(rate / 2)) {
                while gap > 0 {
                    let count = min(gap, silence.count)
                    process(count == silence.count ? silence : Array(silence[0..<count]))
                    gap -= count
                }
            }
            process(samples)
        }
    }

    /// Flushes pending speech and closes the file.
    func finish() {
        queue.sync {
            emitPending()
            file = nil
        }
    }

    // MARK: - Private

    private func process(_ samples: [Float]) {
        writeToFile(samples)
        position += samples.count

        samples.withUnsafeBufferPointer { buf in
            var offset = 0
            // Top up the partial frame left from the previous call first.
            if !frameRemainder.isEmpty {
                let take = min(frameSize - frameRemainder.count, buf.count)
                frameRemainder.append(contentsOf: buf[0..<take])
                offset = take
                guard frameRemainder.count == frameSize else { return }
                frameRemainder.withUnsafeBufferPointer { handleFrame($0) }
                frameRemainder.removeAll(keepingCapacity: true)
            }
            while buf.count - offset >= frameSize {
                handleFrame(UnsafeBufferPointer(rebasing: buf[offset..<offset + frameSize]))
                offset += frameSize
            }
            if offset < buf.count {
                frameRemainder.append(contentsOf: buf[offset...])
            }
        }
    }

    private func handleFrame(_ frame: UnsafeBufferPointer<Float>) {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = sqrt(sum / Float(frame.count))

        let threshold = max(0.004, noiseFloor * 3)
        let isSpeech = rms > threshold
        if isSpeech {
            loudRun += 1
            loudMin = min(loudMin, rms)
            if loudRun >= steadyNoiseFrames {
                // No dip for three seconds: a fan or a noisy room, not speech. Without this the
                // floor never rises, because it only follows frames below the threshold.
                noiseFloor = max(noiseFloor, loudMin)
                loudRun = 0
                loudMin = .infinity
            }
        } else {
            noiseFloor = noiseFloor * 0.995 + rms * 0.005
            loudRun = 0
            loudMin = .infinity
        }

        if pending.isEmpty { pendingStart = vadPos }
        pending.append(contentsOf: frame)
        vadPos += frame.count

        if isSpeech {
            speechFrames += 1
            trailingSilence = 0
        } else {
            trailingSilence += 1
        }
        stats.withLock { $0.level = rms }

        let pendingSeconds = Double(pending.count) / rate
        let speechSec = Double(speechFrames * frameSize) / rate
        let silenceSec = Double(trailingSilence * frameSize) / rate

        if speechFrames == 0 {
            // Nothing said: drop but keep a little lead-in.
            if pendingSeconds > 1.0 { keepTail() }
        } else if silenceSec >= 1.0 && speechSec < minSpeech {
            // A click or a blip.
            keepTail()
        } else if (speechSec >= 0.4 && silenceSec >= 0.7 && pendingSeconds >= 1.5) || silenceSec >= 1.0 || pendingSeconds >= 25 {
            // A full second of silence also ends a short word ("yes"), so it does not wait for the 25 s cut.
            emitPending()
        }
    }

    /// Drops the pending audio except a short lead-in for the speech that may follow.
    private func keepTail() {
        let drop = pending.count - Int(0.3 * rate)
        guard drop > 0 else { return }
        pendingStart += drop
        pending.removeFirst(drop)
        speechFrames = 0
        trailingSilence = 0
    }

    private func emitPending() {
        defer {
            pending.removeAll(keepingCapacity: true)
            speechFrames = 0
            trailingSilence = 0
        }
        let speechSec = Double(speechFrames * frameSize) / rate
        guard speechSec >= minSpeech else { return }
        onChunk(pending, Double(pendingStart) / rate)
    }

    private func writeToFile(_ samples: [Float]) {
        while unwritten > 0 {
            let count = min(unwritten, silence.count)
            guard write(count == silence.count ? silence : Array(silence[0..<count])) else {
                unwritten += samples.count
                return
            }
            unwritten -= count
        }
        if !write(samples) { unwritten += samples.count }
    }

    /// Returns false if the samples did not reach the file.
    private func write(_ samples: [Float]) -> Bool {
        guard let file, !samples.isEmpty else { return true }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioConverter16k.outputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            return true
        } catch {
            let first = stats.withLock { state -> Bool in
                defer { state.writeFailed = true }
                return !state.writeFailed
            }
            if first { NSLog("Writing \(fileURL.lastPathComponent) failed: \(error)") }
            return false
        }
    }
}
