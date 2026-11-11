import Foundation
import Accelerate
import AVFoundation
import WhisperKit
import SpeakerKit

/// Wraps WhisperKit (speech to text) and SpeakerKit (Pyannote diarization).
/// Callers must not run two transcriptions at the same time; AppState serializes access.
final class TranscriptionEngine: @unchecked Sendable {
    private var whisper: WhisperKit?
    private var speakerKit: SpeakerKit?
    private(set) var loadedModel: String?

    var isReady: Bool { whisper != nil }

    // MARK: - Loading

    func prepare(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedModel == model, whisper != nil { return }
        await whisper?.unloadModels()
        whisper = nil
        loadedModel = nil

        let base = Prefs.modelsFolder
        let localFolder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)")

        // Use an earlier download without touching the network.
        if FileManager.default.fileExists(atPath: localFolder.appendingPathComponent("config.json").path) {
            do {
                whisper = try await load(folder: localFolder)
                loadedModel = model
                progress(1)
                return
            } catch {
                NSLog("Local model failed to load, downloading again: \(error)")
            }
        }

        let folder = try await WhisperKit.download(variant: model, downloadBase: base) { p in
            progress(p.fractionCompleted)
        }
        whisper = try await load(folder: folder)
        loadedModel = model
    }

    private func load(folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    /// Frees all models (Whisper and Pyannote). The next `prepare` loads them again.
    func unloadAll() async {
        await whisper?.unloadModels()
        whisper = nil
        loadedModel = nil
        await unloadDiarizer()
    }

    private func diarizer() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        let config = PyannoteConfig(downloadBase: Prefs.modelsFolder.path, verbose: false, logLevel: .error)
        let kit = try await SpeakerKit(config)
        speakerKit = kit
        return kit
    }

    // MARK: - Options

    /// `language` overrides the setting, e.g. with the language detected for a whole track.
    private func options(wordTimestamps: Bool, chunked: Bool, language forced: String? = nil) -> DecodingOptions {
        let language: String? = forced ?? {
            switch Prefs.language {
            case .auto: return nil
            case .de: return "de"
            case .en: return "en"
            }
        }()
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: wordTimestamps,
            chunkingStrategy: chunked ? .vad : ChunkingStrategy.none
        )
    }

    // MARK: - Language

    /// With auto language, detects the language on the busiest 30 s windows of a track.
    /// Returns it when the windows agree, so the whole track is decoded in one language.
    /// Whisper otherwise picks a language per chunk and sometimes translates instead of transcribing.
    private func trackLanguage(_ audio: [Float]) async -> String? {
        guard Prefs.language == .auto, let whisper else { return nil }
        let windows = Self.detectionWindows(audio)
        var votes: [String] = []
        for start in windows {
            let slice = Array(audio[start..<min(audio.count, start + Self.windowSamples)])
            if let result = try? await whisper.detectLangauge(audioArray: slice) { votes.append(result.language) }
        }
        let locked = Self.lockedLanguage(votes)
        NSLog("Language votes \(votes) -> \(locked ?? "auto")")
        return locked
    }

    static let windowSamples = 30 * 16000

    /// Start offsets of up to `count` 30 s windows with the most speech, at least 3 s of it each.
    static func detectionWindows(_ audio: [Float], count: Int = 5) -> [Int] {
        var scored: [(start: Int, active: Double)] = []
        var start = 0
        while start < audio.count {
            let end = min(audio.count, start + windowSamples)
            let active = activeSeconds(Array(audio[start..<end]))
            if active >= 3 { scored.append((start, active)) }
            start += windowSamples
        }
        return scored.sorted { $0.active > $1.active }.prefix(count).map(\.start).sorted()
    }

    /// The language most windows agree on, if at least 75 percent of them do.
    static func lockedLanguage(_ votes: [String]) -> String? {
        guard !votes.isEmpty else { return nil }
        let counts = Dictionary(votes.map { ($0, 1) }, uniquingKeysWith: +)
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Double(top.value) / Double(votes.count) >= 0.75 ? top.key : nil
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Live

    /// Transcribes a short live chunk. Times are relative to the chunk start.
    func transcribeChunk(_ samples: [Float]) async -> [(start: Double, end: Double, text: String)] {
        guard let whisper else { return [] }
        do {
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options(wordTimestamps: false, chunked: false))
            // A chunk is too short to know the speaker's level, so compare against normal speech loudness.
            let levels = HallucinationFilter.frameLevels(samples)
            return results.flatMap(\.segments).compactMap { seg in
                guard let text = HallucinationFilter.clean(seg.text, noSpeechProb: seg.noSpeechProb, avgLogprob: seg.avgLogprob) else { return nil }
                let peak = HallucinationFilter.peak(levels, start: Double(seg.start), end: Double(seg.end))
                if HallucinationFilter.isOnSilence(text, peak: peak, speechLevel: 0.05) { return nil }
                return (Double(seg.start), Double(seg.end), text)
            }
        } catch {
            NSLog("Live transcription failed: \(error)")
            return []
        }
    }

    // MARK: - Final pass

    struct FinalInput {
        var micURL: URL
        var systemURL: URL?
    }

    /// Rough seconds of non-silent audio (100 ms frames above an RMS threshold).
    static func activeSeconds(_ audio: [Float]) -> Double {
        let frame = 1600 // 100 ms at 16 kHz
        var active = 0
        audio.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i + frame <= buf.count {
                var rms: Float = 0
                vDSP_rmsqv(base + i, 1, &rms, vDSP_Length(frame))
                if rms > 0.01 { active += 1 }
                i += frame
            }
        }
        return Double(active) / 10
    }

    /// Call mode when the call track has clearly more than stray system sounds:
    /// over 20 s of activity, or over 10 percent of the recording (and at least 5 s).
    static func isCall(systemActive: Double, totalSeconds: Double) -> Bool {
        systemActive > 20 || (systemActive >= 5 && systemActive > 0.1 * totalSeconds)
    }

    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Full-quality pass over the recorded files with speaker diarization.
    /// Unloads the diarizer afterwards so Pyannote does not stay in memory.
    func finalize(_ input: FinalInput, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        guard let whisper else { throw NSError(domain: "MeetingNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }
        do {
            let segments = try await finalPass(whisper, input, status: status)
            await unloadDiarizer()
            return segments
        } catch {
            await unloadDiarizer()
            throw error
        }
    }

    private func finalPass(_ whisper: WhisperKit, _ input: FinalInput, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        let systemPath = input.systemURL.map(\.path).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }

        // Decide call vs in-person from the system track, then drop it until it is needed.
        var hasCall = false
        if let systemPath {
            let systemAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: systemPath)
            let total = max(Self.duration(of: input.micURL), Double(systemAudio.count) / 16000)
            hasCall = Self.isCall(systemActive: Self.activeSeconds(systemAudio), totalSeconds: total)
        }

        var micAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: input.micURL.path)
        status("Detecting language…")
        let micLanguage = await trackLanguage(micAudio)
        status("Transcribing microphone\(micLanguage.map { " (\(Self.languageName($0)))" } ?? "")…")
        let micResults = Self.dropStrayLanguage(try await whisper.transcribe(
            audioArray: micAudio, decodeOptions: options(wordTimestamps: true, chunked: true, language: micLanguage)))
        let micLevels = HallucinationFilter.frameLevels(micAudio)

        guard hasCall, let systemPath else {
            // In-person meeting: everyone is on the mic, so split the mic track instead.
            status("Identifying speakers…")
            var segments: [TranscriptSegment]
            do {
                let diarization = try await diarizer().diarize(audioArray: micAudio)
                segments = speakerSegments(diarization.addSpeakerInfo(to: micResults), fallback: "me")
            } catch {
                NSLog("Diarization failed: \(error)")
                segments = plainSegments(micResults, speaker: "me")
            }
            segments = HallucinationFilter.dropSilent(segments, levels: micLevels)
            segments.sort { $0.start < $1.start }
            return Self.relabelSpeakers(segments)
        }

        micAudio = []
        let micSegments = HallucinationFilter.dropSilent(plainSegments(micResults, speaker: "me"), levels: micLevels)

        var systemAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: systemPath)
        status("Detecting language…")
        let callLanguage = await trackLanguage(systemAudio)
        status("Transcribing call audio\(callLanguage.map { " (\(Self.languageName($0)))" } ?? "")…")
        let callResults = Self.dropStrayLanguage(try await whisper.transcribe(
            audioArray: systemAudio, decodeOptions: options(wordTimestamps: true, chunked: true, language: callLanguage)))
        let systemLevels = HallucinationFilter.frameLevels(systemAudio)
        status("Identifying speakers…")
        var diarization: DiarizationResult?
        do {
            diarization = try await diarizer().diarize(audioArray: systemAudio)
        } catch {
            NSLog("Diarization failed: \(error)")
        }
        systemAudio = []

        let callSegments = HallucinationFilter.dropSilent(
            diarization.map { speakerSegments($0.addSpeakerInfo(to: callResults), fallback: "them") }
                ?? plainSegments(callResults, speaker: "them"),
            levels: systemLevels)
        let mic = Self.removeEcho(mic: micSegments, call: callSegments)
        return Self.relabelSpeakers((mic + callSegments).sorted { $0.start < $1.start })
    }

    func unloadDiarizer() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }

    // MARK: - Helpers

    /// With auto language, drops short VAD chunks that Whisper decoded in a different language than the rest.
    private static func dropStrayLanguage(_ results: [TranscriptionResult]) -> [TranscriptionResult] {
        guard Prefs.language == .auto, results.count > 1 else { return results }
        let stray = HallucinationFilter.strayLanguageParts(results.map { ($0.language, $0.text) })
        return results.enumerated().filter { !stray.contains($0.offset) }.map(\.element)
    }

    private func plainSegments(_ results: [TranscriptionResult], speaker: String) -> [TranscriptSegment] {
        results.flatMap(\.segments).compactMap { seg in
            guard let text = HallucinationFilter.clean(seg.text, noSpeechProb: seg.noSpeechProb, avgLogprob: seg.avgLogprob) else { return nil }
            return TranscriptSegment(start: Double(seg.start), end: Double(seg.end), speaker: speaker, text: text)
        }
    }

    private func speakerSegments(_ groups: [[SpeakerSegment]], fallback: String) -> [TranscriptSegment] {
        groups.flatMap { $0 }.compactMap { seg in
            let raw = seg.text.isEmpty ? (seg.transcription?.text ?? "") : seg.text
            guard let text = HallucinationFilter.clean(raw, noSpeechProb: seg.transcription?.noSpeechProb ?? 0,
                                                       avgLogprob: seg.transcription?.avgLogprob ?? 0) else { return nil }
            let speaker = seg.speaker.speakerIds.first.map { "raw\($0)" } ?? fallback
            return TranscriptSegment(start: Double(seg.startTime), end: Double(seg.endTime), speaker: speaker, text: text)
        }
    }

    /// Renames raw diarization ids to s1, s2, ... in order of first appearance.
    static func relabelSpeakers(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var map: [String: String] = [:]
        return segments.map { seg in
            var s = seg
            if seg.speaker.hasPrefix("raw") {
                if map[seg.speaker] == nil { map[seg.speaker] = "s\(map.count + 1)" }
                s.speaker = map[seg.speaker]!
            }
            return s
        }
    }

    /// Drops mic lines that are just the call audio leaking from the speakers.
    static func removeEcho(mic: [TranscriptSegment], call: [TranscriptSegment]) -> [TranscriptSegment] {
        mic.filter { m in
            let mWords = Set(HallucinationFilter.words(m.text))
            guard mWords.count >= 3 else { return true }
            for c in call where c.end > m.start - 1 && c.start < m.end + 1 {
                let cWords = Set(HallucinationFilter.words(c.text))
                let overlap = Double(mWords.intersection(cWords).count) / Double(mWords.count)
                if overlap > 0.6 { return false }
            }
            return true
        }
    }
}
