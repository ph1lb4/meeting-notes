import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppState.self) private var state
    let meetingID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary
    @State private var title = ""

    private var meeting: Meeting? { state.meeting(meetingID) }
    private var isRecording: Bool { state.recordingID == meetingID }
    /// Recording or running the final pass. The transcript tab is the default while this is true.
    private var isTranscribing: Bool { isRecording || state.finalizing[meetingID] != nil }

    var body: some View {
        if let meeting {
            VStack(spacing: 0) {
                header(meeting)
                Divider()
                switch tab {
                case .summary: SummaryPage(meeting: meeting)
                case .transcript: TranscriptView(meeting: meeting, autoScroll: isRecording)
                }
            }
            .onAppear {
                title = meeting.title
                tab = isTranscribing ? .transcript : .summary
            }
            .onChange(of: meeting.title) { _, new in title = new }
            .onChange(of: isTranscribing) { _, now in tab = now ? .transcript : .summary }
        }
    }

    // MARK: - Header

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { state.setTitle(title, for: meetingID) }

            HStack(spacing: 12) {
                statusLine(meeting)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func statusLine(_ meeting: Meeting) -> some View {
        if isRecording {
            RecordingStatusView()
        } else if let status = state.finalizing[meetingID] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(status)
            }
            .font(.callout).foregroundStyle(.secondary)
        } else if state.summarizing.contains(meetingID) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.summaryEngines[meetingID].map { "\($0.label) is writing the summary…" } ?? "Writing the summary…")
            }
            .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(max(1, Int(meeting.duration / 60))) min")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Small borderless button used for the per-page actions (copy, run Claude).
struct PageActionButton: View {
    let title: String
    let systemImage: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(help)
    }
}

/// Summary tab: Claude's summary with its actions, then the user's notes.
/// The summary file is loaded into state, not read in `body`.
struct SummaryPage: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    @State private var text: String?
    @State private var loaded = false
    @State private var exportTarget: ExportTarget?

    private struct LoadKey: Hashable {
        var id: UUID
        var folder: String
        var hasSummary: Bool
        var revision: Int
    }

    private var busy: Bool { state.recordingID == meeting.id || state.finalizing[meeting.id] != nil }
    private var summarizing: Bool { state.summarizing.contains(meeting.id) }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
                .padding(.horizontal, 20)
                .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryContent
                    if !meeting.exports.isEmpty {
                        Divider()
                        ExportsSection(meeting: meeting)
                    }
                    Divider()
                    NotesSection(meeting: meeting)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: LoadKey(id: meeting.id, folder: meeting.folderName,
                          hasSummary: meeting.hasSummary, revision: meeting.summaryRevision)) {
            guard meeting.hasSummary else {
                text = nil
                loaded = true
                return
            }
            let url = MeetingStore.folder(for: meeting).appendingPathComponent(MeetingStore.summaryName)
            let content = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            guard !Task.isCancelled else { return }
            text = content
            loaded = true
        }
        .sheet(item: $exportTarget) { target in
            ExportSheet(meeting: meeting, target: target)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            Spacer()
            if meeting.hasSummary, !summarizing {
                ForEach(state.exportTargets) { target in
                    if state.exporting[meeting.id] == target {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Sending to \(target.label)…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        PageActionButton(title: target.label, systemImage: "paperplane",
                                         help: "Send this meeting to \(target.label) with Claude") {
                            exportTarget = target
                        }
                        .disabled(busy || state.exporting[meeting.id] != nil)
                    }
                }
            }
            if let text, !summarizing {
                PageActionButton(title: "Copy", systemImage: "doc.on.doc",
                                 help: "Copy the summary as Markdown (pastes cleanly into Notion)") {
                    state.copyToClipboard(text)
                }
            }
            if summarizing {
                PageActionButton(title: "Cancel", systemImage: "xmark.circle") { state.cancelSummary(meeting.id) }
            } else if meeting.hasSummary {
                PageActionButton(title: "Summarize Again", systemImage: "sparkles",
                                 help: "Write the summary again with \(state.availableEngine?.label ?? "the summary engine")") {
                    state.summarize(meeting.id)
                }
                .disabled(busy || meeting.segments.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if summarizing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("\(state.summaryEngines[meeting.id]?.label ?? "The summary engine") is reading the transcript and your notes…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if let text {
            MarkdownView(markdown: text)
        } else if meeting.hasSummary && !loaded {
            // File is still loading. Stay blank so the empty state does not flash.
            Color.clear.frame(height: 120)
        } else if state.enginesChecked && state.availableEngine == nil {
            NoSummaryEngineView()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(.secondary)
                Text(busy
                     ? "The summary is created once the transcript is finished."
                     : "Create a summary and action items with \(state.availableEngine?.label ?? "Claude").")
                    .foregroundStyle(.secondary)
                Button("Create Summary") { state.summarize(meeting.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || meeting.segments.isEmpty)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }
}

/// Asks where and how to store the meeting, runs Claude with the Notion or Linear tools and shows where it went.
struct ExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let target: ExportTarget

    @State private var request = ""
    @State private var task: Task<Void, Never>?
    @State private var record: ExportRecord?
    @State private var error: String?

    private var running: Bool { task != nil }

    private var placeholder: String {
        switch target {
        case .notion: return "e.g. Add it to the Team Meetings database, tag it Project X"
        case .linear: return "e.g. Team iOS, project Launch, assign to me"
        }
    }

    private var explainer: String {
        switch target {
        case .notion: return "Claude creates a Notion page with the summary, decisions and action items."
        case .linear: return "Claude creates one Linear issue per action item."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send to \(target.label)").font(.title3.weight(.semibold))
            if let record {
                Text("Done. Claude says:").foregroundStyle(.secondary)
                ExportResultView(record: record)
            } else {
                Text(explainer).foregroundStyle(.secondary)
                TextField("Where and how?", text: $request, prompt: Text(placeholder), axis: .vertical)
                    .lineLimit(3...6)
                    .disabled(running)
                Text("Optional. Tell Claude where it goes and anything it should know.")
                    .font(.caption).foregroundStyle(.secondary)
                if running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Claude is working in \(target.label). This can take a minute.").foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(6)
                }
            }
            HStack {
                Spacer()
                if record != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else if running {
                    Button("Stop") { task?.cancel() }
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Send") { send() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.exporting[meeting.id] != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(running)
    }

    private func send() {
        error = nil
        task = Task {
            defer { task = nil }
            do {
                record = try await state.export(meeting.id, to: target, request: request)
            } catch is CancellationError {
                error = "Stopped. Claude may have created some items already."
            } catch {
                self.error = Task.isCancelled ? "Stopped. Claude may have created some items already." : error.localizedDescription
            }
        }
    }
}

/// Claude's report of an export, with clickable links only for the target service.
struct ExportResultView: View {
    let record: ExportRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(markdown: record.result)
            ForEach(ClaudeExporter.links(in: record.result, for: record.target), id: \.self) { url in
                Link(destination: url) {
                    Label("Open in \(record.target.label)", systemImage: "arrow.up.forward.square")
                }
                .font(.callout)
                .help(url.absoluteString)
            }
        }
    }
}

/// Where this meeting was sent before.
struct ExportsSection: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sent to").font(.title3.weight(.semibold))
            ForEach(meeting.exports.reversed()) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(record.target.label) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button {
                            state.deleteExport(record.id, from: meeting.id)
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Remove from this list (does not delete anything in \(record.target.label))")
                    }
                    ExportResultView(record: record)
                        .font(.callout)
                }
            }
        }
    }
}

/// Shown instead of "Create Summary" when neither Claude Code nor Apple Intelligence can be used.
struct NoSummaryEngineView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("No summary yet").font(.headline)
            Text(state.noEngineText)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                SettingsLink { Text("Open Settings") }
                Button("Check Again") { Task { await state.refreshSummaryEngines() } }
            }
            Text("Your transcript is ready either way.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// The user's own notes. They are used when the summary is written.
struct NotesSection: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting

    @State private var noteText = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes").font(.title3.weight(.semibold))
            ForEach(meeting.notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(note.time.timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                    Text(note.text).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        state.deleteNote(note.id, from: meeting.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Delete note")
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                TextField(state.recordingID == meeting.id
                          ? "Add a note, press Enter. The summary uses these."
                          : "Add a note…", text: $noteText)
                    .textFieldStyle(.plain)
                    .focused($noteFocused)
                    .onSubmit {
                        state.addNote(noteText, to: meeting.id)
                        noteText = ""
                        noteFocused = true
                    }
            }
        }
    }
}

/// Clock and level meters of the running recording. The only reader of the live meters in the detail view,
/// so the rest of the view does not redraw on every tick.
struct RecordingStatusView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            ElapsedText(prefix: "Recording ")
            LevelMeter(label: "Mic", level: state.meters.micLevel)
            LevelMeter(label: "Call", level: state.meters.systemLevel)
        }
        .font(.callout)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: geo.size.width * CGFloat(min(1, sqrt(level) * 3)))
                }
            }
            .frame(width: 40, height: 5)
        }
        .font(.caption)
    }
}
