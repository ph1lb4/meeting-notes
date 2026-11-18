import AVFoundation
import CoreAudio
import os

/// Captures everything the Mac plays (Zoom, Teams, Meet in the browser, ...) with a
/// Core Audio process tap. Needs macOS 14.4+ and the "System Audio Recording" permission,
/// which macOS asks for on first use.
final class SystemAudioCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let status): return "\(what) failed (OSStatus \(status))"
            }
        }
    }

    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// IO callbacks run here.
    private let ioQueue = DispatchQueue(label: "SystemAudioCapture.io", qos: .userInitiated)
    /// Start, stop and rebuilds run here, so they never race.
    private let controlQueue = DispatchQueue(label: "SystemAudioCapture.control")
    private let converter = AudioConverter16k()
    private var running = false
    private var rebuildScheduled = false
    private let backoff = RestartBackoff()
    private let failures = OSAllocatedUnfairLock(initialState: 0)
    /// Failed rebuilds in a row since call audio last worked. Read from any thread.
    var failedRestarts: Int { failures.withLock { $0 } }
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Bluetooth headsets (AirPods) drop to a lower sample rate when a call app opens their mic.
    /// The default output device stays the same, so we also watch the format the IO proc was built with.
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var builtFormat: Format?

    private struct Format: Equatable {
        var tapRate: Float64
        var channels: UInt32
        var deviceRate: Float64
    }

    private static let outputDeviceAddresses = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ].map(address)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Throws if call audio could not be set up. Capture then keeps trying in the background,
    /// like after a failed rebuild, so call `stop()` in both cases.
    func start() throws {
        try controlQueue.sync {
            running = true
            addDeviceListener()
            do {
                try build()
            } catch {
                teardown()
                failures.withLock { $0 = 1 }
                scheduleRebuild(after: backoff.delay(afterFailures: 1))
                throw error
            }
        }
    }

    /// Rebuilds a tap that runs but delivers no audio. Nothing is posted then, so the caller
    /// watches the track (`StallWatchdog`).
    func kick() {
        controlQueue.async { [weak self] in
            guard let self, self.running, !self.rebuildScheduled else { return }
            NSLog("System audio capture delivers no audio, rebuilding")
            self.scheduleRebuild(after: 0)
        }
    }

    func stop() {
        controlQueue.sync {
            running = false
            removeDeviceListener()
            teardown()
        }
    }

    // MARK: - Private (all on controlQueue)

    private func build() throws {
        // Tap all processes, mixed down to stereo. Our app plays nothing, so no exclusions needed.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Meeting Notes Tap"

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CaptureError.coreAudio("Creating process tap", status) }

        let outputUID: String
        do { outputUID = try Self.defaultOutputDeviceUID() } catch { teardown(); throw error }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Notes Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { teardown(); throw CaptureError.coreAudio("Creating aggregate device", status) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { teardown(); throw CaptureError.coreAudio("Reading tap format", status) }
        let tapRate = asbd.mSampleRate
        // The IO proc delivers at the aggregate device's rate. After AirPods switch to headset mode
        // the tap still reports 48 kHz while buffers arrive at 24 kHz, which played call audio 2x too fast.
        var deviceRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address = Self.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &deviceRate) == noErr, deviceRate > 0 {
            asbd.mSampleRate = deviceRate
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown(); throw CaptureError.coreAudio("Reading tap format", status)
        }
        NSLog("System audio capture format: tap \(tapRate) Hz, device \(deviceRate) Hz, \(asbd.mChannelsPerFrame) ch")

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            let samples = self.converter.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        guard status == noErr else { teardown(); throw CaptureError.coreAudio("Creating IO proc", status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { teardown(); throw CaptureError.coreAudio("Starting capture", status) }

        builtFormat = currentFormat()
        addFormatListener()
    }

    private func teardown() {
        removeFormatListener()
        builtFormat = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func addDeviceListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        for var address in Self.outputDeviceAddresses {
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
            if status != noErr { NSLog("Listening for output device changes failed (OSStatus \(status))") }
        }
        deviceListener = listener
    }

    private func removeDeviceListener() {
        guard let listener = deviceListener else { return }
        for var address in Self.outputDeviceAddresses {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        }
        deviceListener = nil
    }

    private var formatProperties: [(AudioObjectID, AudioObjectPropertyAddress)] {
        [(tapID, Self.address(kAudioTapPropertyFormat)),
         (aggregateID, Self.address(kAudioDevicePropertyNominalSampleRate))]
    }

    private func currentFormat() -> Format? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        var deviceRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address = Self.address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &deviceRate) == noErr else { return nil }
        return Format(tapRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, deviceRate: deviceRate)
    }

    private func addFormatListener() {
        // Rebuild only on a real change, so a notification fired by our own build cannot loop.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.currentFormat() != self.builtFormat else { return }
            self.scheduleRebuild()
        }
        for (object, var address) in formatProperties {
            let status = AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, listener)
            if status != noErr { NSLog("Listening for audio format changes failed (OSStatus \(status))") }
        }
        formatListener = listener
    }

    private func removeFormatListener() {
        guard let listener = formatListener else { return }
        for (object, var address) in formatProperties where object != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(object, &address, controlQueue, listener)
        }
        formatListener = nil
    }

    /// Both default output properties usually change together, so coalesce them into one rebuild.
    /// A failed rebuild is tried again until it works: the new device may not be ready yet, and
    /// no further change notification is guaranteed to come.
    private func scheduleRebuild(after delay: Double = 0.3) {
        guard running, !rebuildScheduled else { return }
        rebuildScheduled = true
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.running else { return }
            self.teardown()
            do {
                try self.build()
                self.failures.withLock { $0 = 0 }
                NSLog("System audio capture rebuilt")
            } catch {
                self.teardown()
                let failed = self.failures.withLock { count -> Int in
                    count += 1
                    return count
                }
                let delay = self.backoff.delay(afterFailures: failed)
                NSLog("Rebuilding system audio capture failed (\(failed)), next try in \(delay) s: \(error)")
                self.scheduleRebuild(after: delay)
            }
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        // The device apps play on, not the one for alerts (DefaultSystemOutputDevice). It clocks the
        // aggregate device, and the two differ when sound effects go to another output.
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw CaptureError.coreAudio("Reading default output device", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.coreAudio("Reading output device UID", status) }
        return uid.takeRetainedValue() as String
    }
}
