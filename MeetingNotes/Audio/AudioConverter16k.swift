import AVFoundation

/// Converts any PCM buffer to 16 kHz mono Float32, the format Whisper and Pyannote expect.
final class AudioConverter16k {
    static let sampleRate: Double = 16_000
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inputFormat != buffer.format || converter == nil {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return [] }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
