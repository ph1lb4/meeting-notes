import AVFoundation
import Foundation
import Testing

private let rate = 16_000

private func tone(seconds: Double, amplitude: Float = 0.2, frequency: Double = 440, sampleRate: Double = 16_000) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(rate)))
}

/// Speech-like audio: short bursts with a dip between them, like syllables.
private func talk(seconds: Double) -> [Float] {
    var out: [Float] = []
    let count = Int(seconds * Double(rate))
    while out.count < count { out += tone(seconds: 0.24) + silence(seconds: 0.06) }
    return Array(out[0..<count])
}

/// Steady noise, like a fan. About 0.0087 RMS at the default amplitude, above the fixed speech threshold.
private func noise(seconds: Double, amplitude: Float = 0.015) -> [Float] {
    var generator = SystemRandomNumberGenerator()
    return (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
}

private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
}

/// A clock the test moves by hand. Stays at zero unless set, so no silence is padded.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var now: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(samples: [Float], start: Double)] = []
    func add(_ samples: [Float], _ start: Double) { lock.withLock { items.append((samples, start)) } }
    var all: [(samples: [Float], start: Double)] { lock.withLock { items } }
}

private struct Rig {
    let clock = FakeClock()
    let chunks = Chunks()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("track-\(UUID().uuidString).caf")
    let recorder: TrackRecorder

    init() throws {
        let clock = clock, chunks = chunks
        recorder = try TrackRecorder(source: .mic, fileURL: url, clock: { clock.now }) { chunks.add($0, $1) }
    }

    /// Feeds audio in pieces of 100 ms, like a capture device does.
    func feed(_ samples: [Float]) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1600, samples.count)
            recorder.append(Array(samples[offset..<end]))
            offset = end
        }
    }

    /// Closes the file and returns its length in samples.
    func finishAndMeasure() throws -> Int {
        recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }
        return Int(try AVAudioFile(forReading: url).length)
    }
}

@Suite struct TrackRecorderTests {
    @Test func writesEverySample() throws {
        let rig = try Rig()
        rig.feed(tone(seconds: 2.5))
        #expect(try rig.finishAndMeasure() == Int(2.5 * Double(rate)))
    }

    @Test func padsSilenceWhenBehindTheClock() throws {
        let rig = try Rig()
        rig.clock.now = 3
        rig.recorder.append(tone(seconds: 0.1))
        // The 100 ms that just arrived end at second 3.
        #expect(try rig.finishAndMeasure() == 3 * rate)
    }

    @Test func placesFirstAudioExactly() throws {
        // The capture needed 400 ms to start. The track must not begin 300 ms early.
        let rig = try Rig()
        rig.clock.now = 0.4
        rig.recorder.append(tone(seconds: 0.1))
        #expect(try rig.finishAndMeasure() == Int(0.4 * Double(rate)))
    }

    @Test func doesNotPadSmallJitter() throws {
        let rig = try Rig()
        rig.feed(tone(seconds: 1))
        rig.clock.now = 1.5
        rig.recorder.append(tone(seconds: 0.1))
        #expect(try rig.finishAndMeasure() == Int(1.1 * Double(rate)))
    }

    @Test func padsLongGapInPieces() throws {
        let rig = try Rig()
        rig.feed(tone(seconds: 1))
        // The Mac slept for ten minutes.
        rig.clock.now = 601.25
        rig.recorder.append(tone(seconds: 0.1))
        let length = try rig.finishAndMeasure()
        #expect(length == Int(601.25 * Double(rate)))
    }

    @Test func chunkAfterGapStartsAtClockTime() throws {
        let rig = try Rig()
        rig.clock.now = 60
        rig.feed(tone(seconds: 1) + silence(seconds: 1.5))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        let chunks = rig.chunks.all
        #expect(chunks.count == 1)
        // Speech starts near second 59.9, with up to 1 s of lead-in before it.
        if let start = chunks.first?.start { #expect(start > 58.5 && start < 60) }
    }

    @Test func emitsSpeechBetweenSilenceAsOneChunk() throws {
        let rig = try Rig()
        rig.feed(silence(seconds: 3) + tone(seconds: 1) + silence(seconds: 2))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        let chunks = rig.chunks.all
        #expect(chunks.count == 1)
        guard let chunk = chunks.first else { return }
        // Leading silence is dropped down to a short lead-in.
        #expect(chunk.start > 2 && chunk.start <= 3)
        #expect(Double(chunk.samples.count) / Double(rate) < 3)
        #expect(rms(chunk.samples) > 0.05)
    }

    @Test func dropsSilenceAndShortBlips() throws {
        let rig = try Rig()
        rig.feed(silence(seconds: 2) + tone(seconds: 0.1) + silence(seconds: 2))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        #expect(rig.chunks.all.isEmpty)
    }

    @Test func cutsLongSpeechIntoChunks() throws {
        let rig = try Rig()
        rig.feed(talk(seconds: 60))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        let chunks = rig.chunks.all
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { Double($0.samples.count) / Double(rate) <= 25.1 })
        // Nothing is lost between chunks.
        #expect(chunks.reduce(0) { $0 + $1.samples.count } == 60 * rate)
    }

    @Test func emitsShortWordAfterOneSecondOfSilence() throws {
        // A quick "yes" must not wait for the 25 s cut.
        let rig = try Rig()
        rig.feed(silence(seconds: 2) + tone(seconds: 0.3) + silence(seconds: 1.5))
        // Checked before finish(), which would flush it anyway.
        rig.recorder.append(silence(seconds: 0.1))
        let length = try rig.finishAndMeasure()
        #expect(length == Int(3.9 * Double(rate)))
        let chunks = rig.chunks.all
        #expect(chunks.count == 1)
        guard let chunk = chunks.first else { return }
        #expect(Double(chunk.samples.count) / Double(rate) < 3)
        #expect(chunk.start > 0.9 && chunk.start <= 2)
    }

    @Test func steadyNoiseIsNotSpeech() throws {
        // A fan above the fixed threshold. The noise floor has to rise to it, or every frame counts as speech forever.
        let rig = try Rig()
        rig.feed(noise(seconds: 60))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        let total = rig.chunks.all.reduce(0) { $0 + $1.samples.count }
        // Only the first seconds, before the floor adapted.
        #expect(Double(total) / Double(rate) < 6)
    }

    @Test func findsSpeechOverSteadyNoise() throws {
        let rig = try Rig()
        let speech = zip(noise(seconds: 2), tone(seconds: 2)).map { $0 + $1 }
        rig.feed(noise(seconds: 20) + speech + noise(seconds: 3))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        let late = rig.chunks.all.filter { $0.start > 10 }
        #expect(late.count == 1)
        if let chunk = late.first { #expect(chunk.start > 18.9 && chunk.start <= 20) }
    }

    @Test func knowsIfAudioArrivedAndIfItHadSound() throws {
        let rig = try Rig()
        #expect(!rig.recorder.hasAudio)
        rig.feed(silence(seconds: 1))
        // A call track without the system audio permission looks like this: buffers, all zero.
        rig.recorder.finish()
        #expect(rig.recorder.hasAudio)
        #expect(!rig.recorder.heardSound)

        let other = try Rig()
        other.feed(silence(seconds: 1) + tone(seconds: 0.1))
        other.recorder.finish()
        #expect(other.recorder.heardSound)
        try? FileManager.default.removeItem(at: rig.url)
        try? FileManager.default.removeItem(at: other.url)
    }

    @Test func countsSecondsWithoutAudio() throws {
        let rig = try Rig()
        rig.clock.now = 2
        // Nothing arrived yet: counted from the start.
        #expect(rig.recorder.silentFor == 2)
        rig.clock.now = 5
        rig.recorder.append(tone(seconds: 0.1))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        #expect(rig.recorder.silentFor == 0)
        rig.clock.now = 9
        #expect(rig.recorder.silentFor == 4)
    }

    @Test func levelFallsToZeroWhenAudioStops() throws {
        let rig = try Rig()
        rig.feed(tone(seconds: 1))
        rig.recorder.finish()
        try? FileManager.default.removeItem(at: rig.url)
        #expect(rig.recorder.level > 0.05)
        rig.clock.now = 0.5
        #expect(rig.recorder.level > 0.05)
        rig.clock.now = 3
        #expect(rig.recorder.level == 0)
    }
}

@Suite struct AudioConverter16kTests {
    private func buffer(_ samples: [Float], sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }

    /// Converts a signal in pieces of 100 ms, like a live stream.
    private func stream(_ converter: AudioConverter16k, _ samples: [Float], sampleRate: Double, channels: AVAudioChannelCount) -> [Float] {
        let step = Int(sampleRate / 10)
        var out: [Float] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + step, samples.count)
            out += converter.convert(buffer(Array(samples[offset..<end]), sampleRate: sampleRate, channels: channels))
            offset = end
        }
        return out
    }

    @Test func resamples48kStereoTo16kMono() {
        let input = tone(seconds: 2, amplitude: 0.5, sampleRate: 48_000)
        let out = stream(AudioConverter16k(), input, sampleRate: 48_000, channels: 2)
        // The resampler holds back a few samples, it must not lose or invent more than that.
        #expect(abs(out.count - 2 * rate) < 400)
        // Same signal on both channels keeps its level: 0.5 peak is about 0.354 RMS.
        #expect(abs(rms(Array(out.dropFirst(1600))) - 0.354) < 0.03)
    }

    @Test func keepsDurationAt24k() {
        // AirPods in headset mode deliver 24 kHz.
        let out = stream(AudioConverter16k(), tone(seconds: 2, sampleRate: 24_000), sampleRate: 24_000, channels: 1)
        #expect(abs(out.count - 2 * rate) < 400)
    }

    @Test func passes16kMonoThrough() {
        let input = tone(seconds: 1)
        let out = stream(AudioConverter16k(), input, sampleRate: 16_000, channels: 1)
        #expect(out.count == input.count)
        #expect(abs(rms(out) - rms(input)) < 0.001)
    }

    @Test func survivesFormatChangeMidStream() {
        let converter = AudioConverter16k()
        let first = stream(converter, tone(seconds: 1, sampleRate: 48_000), sampleRate: 48_000, channels: 2)
        let second = stream(converter, tone(seconds: 1, sampleRate: 24_000), sampleRate: 24_000, channels: 1)
        #expect(abs(first.count - rate) < 400)
        #expect(abs(second.count - rate) < 400)
        #expect(rms(second) > 0.1)
    }

    @Test func mixesDifferentChannels() {
        // Voice on the left channel only must not vanish in the mono mix.
        let left = tone(seconds: 1, amplitude: 0.5, sampleRate: 48_000)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
        input.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        let out = AudioConverter16k().convert(input)
        #expect(rms(Array(out.dropFirst(1600))) > 0.1)
    }

    @Test func emptyBufferGivesNothing() {
        #expect(AudioConverter16k().convert(buffer([], sampleRate: 48_000, channels: 1)).isEmpty)
    }
}

@Suite struct RestartBackoffTests {
    @Test func delaysGrowUpToTheCap() {
        let backoff = RestartBackoff()
        #expect((1...6).map { backoff.delay(afterFailures: $0) } == [0.5, 1, 2, 4, 5, 5])
        #expect(backoff.delay(afterFailures: 0) == 0.5)
        #expect(backoff.delay(afterFailures: 10_000) == 5)
    }

    @Test func warnsOnlyAfterSeveralFailures() {
        let backoff = RestartBackoff()
        #expect(!backoff.shouldWarn(afterFailures: 0))
        #expect(!backoff.shouldWarn(afterFailures: 3))
        #expect(backoff.shouldWarn(afterFailures: 4))
        #expect(backoff.shouldWarn(afterFailures: 40))
    }
}

@Suite struct StallWatchdogTests {
    @Test func staysQuietWhileAudioArrives() {
        var watchdog = StallWatchdog()
        for step in 0..<100 {
            do { let result = watchdog.update(silentFor: 0.1, at: Double(step) * 0.15); #expect(!result) }
        }
        #expect(!watchdog.shouldWarn(silentFor: 0.1))
    }

    @Test func restartsAStalledTrackWithGrowingPauses() {
        var watchdog = StallWatchdog()
        var restarts: [Double] = []
        // Audio stops at second 0 and never comes back. Checked every 150 ms, like the meter timer.
        for step in 0..<400 {
            let time = Double(step) * 0.15
            if watchdog.update(silentFor: time, at: time) { restarts.append(time) }
        }
        #expect(restarts.count >= 4 && restarts.count <= 12)
        #expect(restarts.first == 3)
        let pauses = zip(restarts.dropFirst(), restarts).map { $0 - $1 }
        // Each restart gets at least the stall time to deliver audio.
        #expect(pauses.allSatisfy { $0 >= 3.5 })
        #expect(pauses.last! <= 8.2)
    }

    @Test func startsOverOnceAudioIsBack() {
        var watchdog = StallWatchdog()
        do { let result = watchdog.update(silentFor: 3, at: 3); #expect(result) }
        do { let result = watchdog.update(silentFor: 3.2, at: 3.2); #expect(!result) }
        do { let result = watchdog.update(silentFor: 0.1, at: 4); #expect(!result) }
        // A new stall is restarted right at the limit again.
        do { let result = watchdog.update(silentFor: 3, at: 7); #expect(result) }
    }

    @Test func warnsOnlyWhenRestartsDidNotHelp() {
        let watchdog = StallWatchdog()
        #expect(!watchdog.shouldWarn(silentFor: 5))
        #expect(watchdog.shouldWarn(silentFor: 12))
    }
}

@Suite struct SilentCallCheckTests {
    @Test func warnsOnceWhenACallStaysSilent() {
        var check = SilentCallCheck()
        var warnings: [Double] = []
        for second in 0..<200 where check.update(otherAppUsesMic: true, callAudioHeard: false, at: Double(second)) {
            warnings.append(Double(second))
        }
        #expect(warnings == [45])
    }

    @Test func staysQuietOnceCallAudioWasHeard() {
        var check = SilentCallCheck()
        for second in 0..<200 {
            do { let result = check.update(otherAppUsesMic: true, callAudioHeard: second >= 20, at: Double(second)); #expect(!result) }
        }
    }

    @Test func staysQuietWithoutACall() {
        var check = SilentCallCheck()
        for second in 0..<200 {
            do { let result = check.update(otherAppUsesMic: false, callAudioHeard: false, at: Double(second)); #expect(!result) }
        }
    }

    @Test func shortMicUseByAnotherAppDoesNotCount() {
        var check = SilentCallCheck()
        // Dictation for 30 s, a pause, then 30 s again.
        for second in 0..<100 {
            let inUse = second < 30 || (40..<70).contains(second)
            do { let result = check.update(otherAppUsesMic: inUse, callAudioHeard: false, at: Double(second)); #expect(!result) }
        }
    }
}
