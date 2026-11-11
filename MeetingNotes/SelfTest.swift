import Foundation
import WhisperKit

/// Headless check of the pipeline: `Meeting Notes --selftest <mic.wav> <system.wav>`.
/// Runs the final pass (Whisper + diarization) and the Claude summary, prints results, exits.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--apple-summary-test") { runAppleSummaryTest() }
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
                    let out = args.contains("--apple")
                        ? try await AppleSummarizer.run(for: meeting)
                        : try await ClaudeRunner.run(for: meeting, workingDirectory: FileManager.default.temporaryDirectory)
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

    /// `Meeting Notes --apple-summary-test`: summarizes a long made-up meeting with Apple Intelligence,
    /// long enough to go through the part-by-part path.
    private static func runAppleSummaryTest() {
        Prefs.registerDefaults()
        Task.detached {
            var meeting = Meeting(title: "Apple test", createdAt: Date(), folderName: "selftest")
            let lines = [
                ("me", "Let's go through the launch plan for the new app. We want to ship in March."),
                ("them", "Design is almost done. Anna still needs to finish the onboarding screens by Friday."),
                ("me", "What about the backend? Are the payment endpoints ready?"),
                ("them", "Payments work in staging. Tom will test refunds next week."),
                ("me", "Good. We decided to drop the Android version for the first release."),
                ("them", "Open question is the pricing. Monthly or yearly only? We need data first."),
                ("me", "I will ask the marketing team for the survey results and send them around."),
            ]
            var t = 0.0
            for round in 0..<12 {
                for (speaker, text) in lines {
                    meeting.segments.append(TranscriptSegment(start: t, end: t + 5, speaker: speaker, text: "\(text) (round \(round))"))
                    t += 5
                }
            }
            meeting.duration = t
            print("status:", AppleSummarizer.status)
            do {
                let t0 = Date()
                let out = try await AppleSummarizer.run(for: meeting)
                print("done in \(Int(Date().timeIntervalSince(t0)))s")
                print("TITLE:", out.title ?? "-")
                print(out.summary)
                print(out.actionItems)
                exit(0)
            } catch {
                print("APPLE TEST FAILED:", error)
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    }
}
