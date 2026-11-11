import CoreAudio
import Foundation

/// Asks Core Audio which processes record audio right now. Used to notice when a call app lets go of the mic.
enum MicUsage {
    /// True if any process other than this app is capturing audio input.
    static func otherAppIsUsingMic() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return false }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        let me = getpid()
        for id in ids.prefix(count) {
            guard let pid: pid_t = read(id, kAudioProcessPropertyPID), pid != me else { continue }
            if let running: UInt32 = read(id, kAudioProcessPropertyIsRunningInput), running != 0 { return true }
        }
        return false
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? where T: FixedWidthInteger {
        var address = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
