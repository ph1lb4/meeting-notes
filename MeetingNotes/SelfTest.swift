import Foundation
import WhisperKit

/// Headless check of the pipeline: `Meeting Notes --selftest <mic.wav> <system.wav>`.
/// Runs the final pass (Whisper + diarization) and the Claude summary, prints results, exits.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let mic = URL(fileURLWithPath: args[i + 1])
        let system = URL(fileURLWithPath: args[i + 2])
        Prefs.registerDefaults()

        Task.detached {
            let engine = TranscriptionEngine()
            do {
                let t0 = Date()
                try await engine.prepare(model: Prefs.model) { p in print(String(format: "download %.0f%%", p * 100)) }
                print("model ready in \(Int(Date().timeIntervalSince(t0)))s")

                let live = try await engine.transcribeChunk(Array(loadSamples(system).prefix(16000 * 8)))
                print("live chunk:", live.map(\.text))

                let t1 = Date()
                let segments = try await engine.finalize(.init(micURL: mic, systemURL: system)) { print("status:", $0) }
                print("final pass in \(Int(Date().timeIntervalSince(t1)))s")

                var meeting = Meeting(title: "Self test", createdAt: Date(), folderName: "selftest")
                meeting.segments = segments
                meeting.duration = segments.last?.end ?? 0
                meeting.notes = [MeetingNote(time: 5, text: "Budget is the main topic")]
                print(MarkdownExporter.transcript(for: meeting))

                if !args.contains("--no-claude") {
                    let out = try await ClaudeRunner.run(for: meeting, workingDirectory: FileManager.default.temporaryDirectory)
                    print("TITLE:", out.title ?? "-")
                    print(out.summary)
                    print(out.actionItems)
                }
                exit(0)
            } catch {
                print("SELFTEST FAILED:", error)
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    }
}
