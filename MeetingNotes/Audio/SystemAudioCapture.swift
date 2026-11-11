import AVFoundation
import CoreAudio

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
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static let outputDeviceAddresses = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ].map {
        AudioObjectPropertyAddress(mSelector: $0,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func start() throws {
        try controlQueue.sync {
            try build()
            running = true
            addDeviceListener()
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
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown(); throw CaptureError.coreAudio("Reading tap format", status)
        }

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
    }

    private func teardown() {
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

    /// Both default output properties usually change together, so coalesce them into one rebuild.
    private func scheduleRebuild() {
        guard running, !rebuildScheduled else { return }
        rebuildScheduled = true
        controlQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.running else { return }
            self.teardown()
            do {
                try self.build()
                NSLog("System audio capture rebuilt after output device change")
            } catch {
                NSLog("Rebuilding system audio capture failed: \(error)")
            }
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
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
