import AVFoundation
import AudioToolbox
import os

/// Captures the microphone chosen in Settings (or the system default if none is set or it is missing). Echo of call audio played through speakers is removed
/// later in the final pass (`removeEcho`), not here.
/// Restarts itself when the audio configuration changes (AirPods connect, input device switch).
final class MicCapture {
    /// Built fresh on every start. A reused engine keeps the input format it saw first, so after a
    /// device or sample rate change (another app in a call, AirPods) it fails with -10868.
    private var engine = AVAudioEngine()
    private let converter = AudioConverter16k()
    private let queue = DispatchQueue(label: "MicCapture")
    private var stopped = true
    /// Bumped on each configuration change so stale retries stop.
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    private let backoff = RestartBackoff()
    private let failures = OSAllocatedUnfairLock(initialState: 0)
    /// Failed restarts in a row since the mic last worked. Read from any thread.
    var failedRestarts: Int { failures.withLock { $0 } }
    var onSamples: (([Float]) -> Void)?

    enum MicError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input available. Check the input device in System Settings > Sound." }
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        try queue.sync {
            try startWithFallback()
            stopped = false
        }
        // object: nil because the engine is replaced on every restart.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let sender = note.object as AnyObject?
            self.queue.async {
                guard sender === self.engine else { return }
                self.generation += 1
                self.restart(generation: self.generation)
            }
        }
    }

    /// Restarts an engine that runs but delivers no audio. No configuration change is posted
    /// then, so the caller watches the track (`StallWatchdog`).
    func kick() {
        queue.async { [weak self] in
            // With failed restarts a retry is already on its way.
            guard let self, !self.stopped, self.failedRestarts == 0 else { return }
            NSLog("Mic delivers no audio, restarting")
            self.generation += 1
            self.restart(generation: self.generation)
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        queue.sync {
            stopped = true
            tearDown()
        }
    }

    /// Runs on `queue`. Tries the mic from Settings, then the system default.
    private func startWithFallback() throws {
        do {
            try startEngine(useSelectedDevice: true)
        } catch where !Prefs.micDeviceUID.isEmpty {
            NSLog("Selected mic failed (\(error)), trying the system default")
            try startEngine(useSelectedDevice: false)
        }
    }

    /// Runs on `queue`.
    private func tearDown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Runs on `queue`.
    private func startEngine(useSelectedDevice: Bool) throws {
        tearDown()
        engine = AVAudioEngine()
        let input = engine.inputNode
        if useSelectedDevice { selectDevice(on: input) }

        // While the device switches, the formats can be empty or stale.
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { throw MicError.noInput }
        matchOutputFormat(of: input, to: hwFormat)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInput }
        NSLog("Mic format: device \(hwFormat.sampleRate) Hz \(hwFormat.channelCount) ch, tap \(format.sampleRate) Hz \(format.channelCount) ch")

        // No explicit format: AVAudioEngine raises an Objective-C exception (which Swift cannot
        // catch, so the app aborts) when a passed format does not match the hardware rate.
        // With nil the tap takes the bus format, and the converter handles any format.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.converter.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw error
        }
    }

    /// The input unit cannot resample. If its output side still has the rate of the device it saw
    /// before (switched device, or another app changed the rate), the engine fails to start, so
    /// set the output side to the device's rate.
    private func matchOutputFormat(of input: AVAudioInputNode, to hwFormat: AVAudioFormat) {
        let current = input.outputFormat(forBus: 0)
        guard current.sampleRate != hwFormat.sampleRate || current.channelCount != hwFormat.channelCount,
              let unit = input.audioUnit,
              let wanted = AVAudioFormat(standardFormatWithSampleRate: hwFormat.sampleRate, channels: hwFormat.channelCount)
        else { return }
        var asbd = wanted.streamDescription.pointee
        let status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        NSLog("Mic output format \(current.sampleRate) Hz -> \(hwFormat.sampleRate) Hz: \(status)")
    }

    /// Points the input node at the chosen device. Falls back to the system default when the
    /// device is not connected. Runs on `queue` while the engine is stopped.
    private func selectDevice(on input: AVAudioInputNode) {
        let uid = Prefs.micDeviceUID
        guard !uid.isEmpty else { return }
        guard var deviceID = AudioInputDevices.deviceID(forUID: uid) else {
            NSLog("Selected mic \(uid) not connected, using system default")
            return
        }
        guard let unit = input.audioUnit else { return }
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { NSLog("Could not select mic \(uid): \(status)") }
    }

    /// Runs on `queue`. The format can be invalid for a moment while the device switches, so retry.
    /// Never gives up while recording: a stopped engine posts no more configuration changes, so
    /// nothing else would bring the mic back.
    /// Failures are counted until a restart works, also across configuration changes, so a
    /// device that keeps changing cannot hold the warning back.
    private func restart(generation: Int) {
        guard !stopped, generation == self.generation else { return }
        do {
            try startWithFallback()
            failures.withLock { $0 = 0 }
            NSLog("Mic restarted")
        } catch {
            let failed = failures.withLock { count -> Int in
                count += 1
                return count
            }
            let delay = backoff.delay(afterFailures: failed)
            NSLog("Mic restart \(failed) failed, next try in \(delay) s: \(error)")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restart(generation: generation)
            }
        }
    }
}
