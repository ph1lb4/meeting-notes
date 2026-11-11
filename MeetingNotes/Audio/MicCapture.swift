import AVFoundation
import AudioToolbox

/// Captures the microphone chosen in Settings (or the system default if none is set or it is missing). Echo of call audio played through speakers is removed
/// later in the final pass (`removeEcho`), not here.
/// Restarts itself when the audio configuration changes (AirPods connect, input device switch).
final class MicCapture {
    private let engine = AVAudioEngine()
    private let converter = AudioConverter16k()
    private let queue = DispatchQueue(label: "MicCapture")
    private var stopped = true
    /// Bumped on each configuration change so stale retries stop.
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    private let maxRestartAttempts = 6
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
            try startEngine()
            stopped = false
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.generation += 1
                self.restart(attempt: 0, generation: self.generation)
            }
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        queue.sync {
            stopped = true
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Runs on `queue`.
    private func startEngine() throws {
        let input = engine.inputNode
        selectDevice(on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.converter.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
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
    private func restart(attempt: Int, generation: Int) {
        guard !stopped, generation == self.generation else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine()
            NSLog("Mic restarted after audio configuration change")
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            guard attempt + 1 < maxRestartAttempts else {
                NSLog("Mic restart failed, giving up: \(error)")
                return
            }
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restart(attempt: attempt + 1, generation: generation)
            }
        }
    }
}
