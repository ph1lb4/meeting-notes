import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppState.self) private var state
    let meetingID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case summary = "Summary"
        case actions = "Action Items"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .transcript
    @State private var title = ""
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool

    private var meeting: Meeting? { state.meeting(meetingID) }
    private var isRecording: Bool { state.recordingID == meetingID }

    var body: some View {
        if let meeting {
            VStack(spacing: 0) {
                header(meeting)
                Divider()
                switch tab {
                case .transcript: TranscriptView(meeting: meeting, autoScroll: isRecording)
                case .summary: GeneratedTextView(meeting: meeting, file: MeetingStore.summaryName)
                case .actions: GeneratedTextView(meeting: meeting, file: MeetingStore.actionItemsName)
                }
                if tab == .transcript { noteBar }
            }
            .onAppear { title = meeting.title }
            .onChange(of: meeting.title) { _, new in title = new }
            .toolbar { toolbar(meeting) }
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
                .frame(width: 300)
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
                Text("Claude is writing the summary…")
                Button("Cancel") { state.cancelSummary(meetingID) }
                    .controlSize(.small)
            }
            .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(max(1, Int(meeting.duration / 60))) min")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Notes

    private var noteBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text").foregroundStyle(.secondary)
            TextField(isRecording ? "Add a note, press Enter. Claude uses these for the summary." : "Add a note…", text: $noteText)
                .textFieldStyle(.plain)
                .focused($noteFocused)
                .onSubmit {
                    state.addNote(noteText, to: meetingID)
                    noteText = ""
                    noteFocused = true
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                state.copyToClipboard(currentMarkdown(meeting))
            } label: {
                Label("Copy Markdown", systemImage: "doc.on.doc")
            }
            .help("Copy this tab as Markdown (pastes cleanly into Notion)")

            Button {
                state.summarize(meetingID)
            } label: {
                Label(meeting.hasSummary ? "Regenerate Summary" : "Summarize", systemImage: "sparkles")
            }
            .help(meeting.hasSummary ? "Run Claude again" : "Create summary and action items with Claude")
            .disabled(isRecording || state.finalizing[meetingID] != nil || state.summarizing.contains(meetingID) || meeting.segments.isEmpty)

            Menu {
                Button("Show in Finder") { state.revealInFinder(meetingID) }
                if state.hasAudio(meeting) {
                    Button("Transcribe Again from Audio") { state.retranscribe(meetingID) }
                        .disabled(isRecording || state.finalizing[meetingID] != nil)
                }
                Divider()
                Button("Delete Meeting", role: .destructive) { state.delete(meetingID) }
                    .disabled(isRecording)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func currentMarkdown(_ meeting: Meeting) -> String {
        switch tab {
        case .transcript: return MarkdownExporter.transcript(for: meeting)
        case .summary: return MeetingStore.read(MeetingStore.summaryName, of: meeting) ?? ""
        case .actions: return MeetingStore.read(MeetingStore.actionItemsName, of: meeting) ?? ""
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

/// Summary or action items tab. The file is loaded into state, not read in `body`.
struct GeneratedTextView: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let file: String

    @State private var text: String?
    @State private var loaded = false

    private struct LoadKey: Hashable {
        var id: UUID
        var file: String
        var folder: String
        var hasSummary: Bool
        var revision: Int
    }

    private var busy: Bool { state.recordingID == meeting.id || state.finalizing[meeting.id] != nil }

    var body: some View {
        Group {
            if state.summarizing.contains(meeting.id) {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Claude is reading the transcript and your notes…").foregroundStyle(.secondary)
                    Button("Cancel") { state.cancelSummary(meeting.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text {
                ScrollView {
                    MarkdownView(markdown: text)
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if meeting.hasSummary && !loaded {
                // File is still loading. Stay blank so the empty state does not flash.
                Color.clear
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(busy
                         ? "The summary is created once the transcript is finished."
                         : "Create a summary and action items with Claude.")
                        .foregroundStyle(.secondary)
                    Button("Create Summary") { state.summarize(meeting.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || meeting.segments.isEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(id: meeting.id, file: file, folder: meeting.folderName,
                          hasSummary: meeting.hasSummary, revision: meeting.summaryRevision)) {
            guard meeting.hasSummary else {
                text = nil
                loaded = true
                return
            }
            let url = MeetingStore.folder(for: meeting).appendingPathComponent(file)
            let content = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            guard !Task.isCancelled else { return }
            text = content
            loaded = true
        }
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
