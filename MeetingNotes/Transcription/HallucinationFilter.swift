import Foundation
import Accelerate

/// Whisper likes to invent text on silence ("Untertitel im Auftrag des ZDF", "Thanks for watching").
/// This strips the usual suspects.
enum HallucinationFilter {
    /// Phrases that hint at a hallucination. Only drop on these when the decoder was also unsure.
    private static let blocked = [
        "untertitel", "amara.org", "zdf", "copyright", "swr ", "wdr",
        "thanks for watching", "thank you for watching", "vielen dank fürs zuschauen",
        "danke fürs zuschauen", "bis zum nächsten mal", "subscribe", "abonniert",
        "www.", "mooji",
    ]

    /// Classic full-phrase hallucinations. Dropped on their own when the segment is short.
    private static let classic = [
        "thanks for watching", "thank you for watching", "vielen dank fürs zuschauen",
        "danke fürs zuschauen", "untertitel im auftrag des zdf", "untertitel der amara.org-community",
        "bis zum nächsten mal",
    ]

    /// Short lines Whisper invents on near silence. People say them too, so they only go when the
    /// decoder is unsure or the audio under them is quiet.
    private static let fillers: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks", "you", "bye", "bye bye",
        "okay", "ok", "so", "amen", "danke", "danke schön", "vielen dank", "tschüss", "ja",
    ]

    static func isFiller(_ text: String) -> Bool {
        fillers.contains(words(text).joined(separator: " "))
    }

    private static let soundWords = "music|musik|applause|applaus|laughter|lachen|laughs|lacht|silence|stille|noise|geräusche|geräusch|inaudible|unverständlich|blank_audio"

    static func clean(_ raw: String, noSpeechProb: Float, avgLogprob: Float) -> String? {
        var text = raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        // Sound annotations like [Musik], (applause), *laughs*. Normal parentheses stay.
        text = text.replacingOccurrences(
            of: "(?i)[\\[\\(\\*]\\s*(?:\(soundWords))\\b[^\\]\\)\\*]{0,30}[\\]\\)\\*]",
            with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count > 1 else { return nil }
        if noSpeechProb > 0.6 && avgLogprob < -0.8 { return nil }
        let lower = text.lowercased()
        let unsure = noSpeechProb > 0.3 || avgLogprob < -0.6
        if unsure, text.count < 80, blocked.contains(where: { lower.contains($0) }) { return nil }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if isFiller(text), noSpeechProb > 0.2 || avgLogprob < -0.5 { return nil }
        if wordCount <= 6, classic.contains(where: { lower.contains($0) }) { return nil }
        if text.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return nil }
        return text
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    // MARK: - Audio level checks

    static let frameSamples = 1600 // 100 ms at 16 kHz

    /// RMS of each 100 ms frame of 16 kHz audio.
    static func frameLevels(_ audio: [Float]) -> [Float] {
        var levels: [Float] = []
        levels.reserveCapacity(audio.count / frameSamples + 1)
        audio.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i < buf.count {
                let n = min(frameSamples, buf.count - i)
                var rms: Float = 0
                vDSP_rmsqv(base + i, 1, &rms, vDSP_Length(n))
                levels.append(rms)
                i += frameSamples
            }
        }
        return levels
    }

    /// Typical speech loudness of a track: 90th percentile of the frames above the noise floor.
    static func speechLevel(_ levels: [Float]) -> Float {
        let active = levels.filter { $0 > 0.002 }.sorted()
        guard !active.isEmpty else { return 0 }
        return active[min(active.count - 1, Int(Double(active.count) * 0.9))]
    }

    /// Loudest 100 ms frame between start and end (seconds).
    static func peak(_ levels: [Float], start: Double, end: Double) -> Float {
        let a = max(0, Int(start * 10))
        let b = min(levels.count, Int((end * 10).rounded(.up)) + 1)
        guard a < b else { return 0 }
        return levels[a..<b].max() ?? 0
    }

    /// True when a line sits on (near) silence: nothing in its window is loud enough to be speech,
    /// or it is a filler like "Thank you." over audio well below the track's speech level.
    static func isOnSilence(_ text: String, peak: Float, speechLevel: Float) -> Bool {
        if peak < max(0.003, speechLevel * 0.04) { return true }
        if isFiller(text), peak < max(0.01, speechLevel * 0.3) { return true }
        return false
    }

    /// Drops segments that sit on silence in the given track.
    static func dropSilent(_ segments: [TranscriptSegment], levels: [Float]) -> [TranscriptSegment] {
        let level = speechLevel(levels)
        return segments.filter { !isOnSilence($0.text, peak: peak(levels, start: $0.start, end: $0.end), speechLevel: level) }
    }

    /// With auto language, Whisper sometimes "detects" a random language on noise and writes gibberish.
    /// Returns the indices of short parts whose language differs from the one most of the text is in.
    static func strayLanguageParts(_ parts: [(language: String, text: String)]) -> Set<Int> {
        var chars: [String: Int] = [:]
        for p in parts { chars[p.language, default: 0] += p.text.count }
        guard let main = chars.max(by: { $0.value < $1.value })?.key else { return [] }
        let total = chars.values.reduce(0, +)
        guard Double(chars[main]!) >= 0.6 * Double(total) else { return [] }
        return Set(parts.indices.filter { parts[$0].language != main && parts[$0].text.count < 120 })
    }
}
