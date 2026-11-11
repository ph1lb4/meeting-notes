import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.selectedID) {
                ForEach(state.meetings) { m in
                    MeetingRow(meeting: m, isRecording: state.recordingID == m.id)
                        .tag(m.id)
                        .contextMenu {
                            Button("Show in Finder") { state.revealInFinder(m.id) }
                            Button("Delete", role: .destructive) { state.delete(m.id) }
                                .disabled(state.recordingID == m.id)
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) { ModelStatusView().padding(10) }
        } detail: {
            if let id = state.selectedID, state.meeting(id) != nil {
                MeetingDetailView(meetingID: id)
                    .id(id)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert("Heads up", isPresented: Binding(get: { state.warningMessage != nil }, set: { if !$0 { state.warningMessage = nil } })) {
            Button("OK") { state.warningMessage = nil }
        } message: {
            Text(state.warningMessage ?? "")
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isRecording {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text(meeting.title).lineLimit(1)
            }
            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct RecordButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.toggleRecording()
        } label: {
            if state.isRecording {
                Label {
                    ElapsedText(prefix: "Stop ")
                } icon: {
                    Image(systemName: "stop.circle.fill")
                }
                .foregroundStyle(.red)
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .labelStyle(.titleAndIcon)
        .help(state.isRecording ? "Stop recording" : "Start a new meeting recording (⇧⌘R)")
    }
}

/// Running clock of the current recording. Reads the live meters, so keep it a leaf view.
struct ElapsedText: View {
    @Environment(AppState.self) private var state
    var prefix = ""

    var body: some View {
        Text("\(prefix)\(state.meters.elapsed.timestamp)").monospacedDigit()
    }
}

struct ModelStatusView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.modelStatus {
        case .ready, .idle:
            EmptyView()
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading Whisper model…").font(.caption)
                ProgressView(value: p)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model (first time takes a few minutes)").font(.caption)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text("Model failed: \(msg)").font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { state.prepareModel() }.controlSize(.small)
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No meeting selected").font(.title3)
            Text("Start a recording when your call begins.\nEverything is transcribed on this Mac.\nClaude writes the summary, so the transcript is sent to Anthropic when you summarize.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                state.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
