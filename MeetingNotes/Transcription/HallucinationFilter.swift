import Foundation

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
        if wordCount <= 6, classic.contains(where: { lower.contains($0) }) { return nil }
        if text.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return nil }
        return text
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }
}
