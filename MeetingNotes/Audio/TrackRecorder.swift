import AVFoundation
import os

/// One audio track (mic or system). Writes 16 kHz audio to disk, keeps it aligned to the
/// wall clock, and cuts speech into chunks for live transcription using a simple energy VAD.
final class TrackRecorder {
    typealias ChunkHandler = (_ samples: [Float], _ startTime: Double) -> Void

    let source: AudioSource
    let fileURL: URL
    private let startDate: Date
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private let onChunk: ChunkHandler

    private let rate = AudioConverter16k.sampleRate
    private let frameSize = 480 // 30 ms
    private var written: Int = 0
    /// Sample index of the next VAD frame.
    private var vadPos: Int = 0

    // VAD state
    private var pending: [Float] = []
    private var pendingStart: Int = 0
    private var frameRemainder: [Float] = []
    private var speechFrames = 0
    private var trailingSilence = 0
    private var noiseFloor: Float = 0.002

    private struct Stats {
        var level: Float = 0
        var speechSeconds: Double = 0
        var writeFailed = false
    }
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    /// Last RMS level, for the UI meter. Read from any thread.
    var level: Float { stats.withLock { $0.level } }
    /// Total seconds classified as speech, used to decide if the call track had anyone talking.
    var speechSeconds: Double { stats.withLock { $0.speechSeconds } }
    /// True once a write to the audio file failed. Recording continues, but the file is incomplete.
    var writeFailed: Bool { stats.withLock { $0.writeFailed } }

    init(source: AudioSource, fileURL: URL, startDate: Date, onChunk: @escaping ChunkHandler) throws {
        self.source = source
        self.fileURL = fileURL
        self.startDate = startDate
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
        queue.async { [self] in
            guard file != nil else { return }
            // Pad silence if this track is behind the wall clock (late start, device gap).
            let expected = Int(Date().timeIntervalSince(startDate) * rate) - samples.count
            if expected - written > Int(rate / 2) {
                process(Array(repeating: 0, count: expected - written))
            }
            process(samples)
        }
    }

    /// Flushes pending speech and closes the file.
    func finish() {
        queue.sync {
            emitPending(force: true)
            file = nil
        }
    }

    // MARK: - Private

    private func process(_ samples: [Float]) {
        writeToFile(samples)
        written += samples.count

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
        if !isSpeech {
            noiseFloor = noiseFloor * 0.995 + rms * 0.005
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
        let frameSeconds = isSpeech ? Double(frameSize) / rate : 0
        stats.withLock {
            $0.level = rms
            $0.speechSeconds += frameSeconds
        }

        let pendingSeconds = Double(pending.count) / rate
        let speechSec = Double(speechFrames * frameSize) / rate
        let silenceSec = Double(trailingSilence * frameSize) / rate

        if speechFrames == 0 && pendingSeconds > 1.0 {
            // Nothing said: drop but keep a little lead-in.
            let keep = Int(0.3 * rate)
            pendingStart += pending.count - keep
            pending.removeFirst(pending.count - keep)
            trailingSilence = 0
        } else if (speechSec >= 0.4 && silenceSec >= 0.7 && pendingSeconds >= 1.5) || pendingSeconds >= 25 {
            emitPending(force: false)
        }
    }

    private func emitPending(force: Bool) {
        defer {
            pending.removeAll()
            speechFrames = 0
            trailingSilence = 0
        }
        let speechSec = Double(speechFrames * frameSize) / rate
        guard speechSec >= 0.3 else { return }
        onChunk(pending, Double(pendingStart) / rate)
    }

    private func writeToFile(_ samples: [Float]) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: AudioConverter16k.outputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
        } catch {
            let first = stats.withLock { state -> Bool in
                defer { state.writeFailed = true }
                return !state.writeFailed
            }
            if first { NSLog("Writing \(fileURL.lastPathComponent) failed: \(error)") }
        }
    }
}
