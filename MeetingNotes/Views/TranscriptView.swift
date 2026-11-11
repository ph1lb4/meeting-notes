import SwiftUI

struct TranscriptView: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let autoScroll: Bool

    private var busy: Bool { state.recordingID == meeting.id || state.finalizing[meeting.id] != nil }

    var body: some View {
        let entries = meeting.timeline
        let speakers = meeting.speakerKeys
        VStack(spacing: 0) {
            if !speakers.isEmpty || !entries.isEmpty {
                HStack(spacing: 0) {
                    SpeakerBar(meeting: meeting, keys: speakers)
                    Spacer(minLength: 0)
                    if !meeting.segments.isEmpty && !busy {
                        if !meeting.originalTexts.isEmpty {
                            PageActionButton(title: "Undo Fixes", systemImage: "arrow.uturn.backward",
                                             help: "Put back the \(meeting.originalTexts.count) lines Claude changed") {
                                state.restoreOriginalTranscript(meeting.id)
                            }
                            .padding(.trailing, 14)
                        }
                        if state.canCleanUp {
                            PageActionButton(title: "Fix with Claude", systemImage: "wand.and.stars",
                                             help: "Let Claude correct misheard words, names and terms") {
                                state.cleanUpTranscript(meeting.id)
                            }
                            .disabled(state.summarizing.contains(meeting.id))
                            .padding(.trailing, 14)
                        }
                    }
                    if !meeting.segments.isEmpty {
                        PageActionButton(title: "Copy", systemImage: "doc.on.doc",
                                         help: "Copy the transcript as Markdown (pastes cleanly into Notion)") {
                            state.copyToClipboard(MarkdownExporter.transcript(for: meeting))
                        }
                        .padding(.trailing, 20)
                    }
                }
                Divider()
            }
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(state.recordingID == meeting.id ? "Listening… text shows up after the first sentence." : "No transcript.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(entries) { entry in
                                row(entry).id(entry.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    }
                    .onChange(of: entries.count) {
                        if autoScroll { withAnimation { proxy.scrollTo("bottom") } }
                    }
                    .onAppear { if autoScroll { proxy.scrollTo("bottom") } }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: Meeting.Entry) -> some View {
        switch entry {
        case .segment(let seg):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(seg.start.timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.displayName(for: seg.speaker))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpeakerColor.color(for: seg.speaker))
                    Text(seg.text)
                }
            }
        case .note(let note):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(note.time.timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "note.text")
                    Text(note.text)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button("Delete Note", role: .destructive) { state.deleteNote(note.id, from: meeting.id) }
                }
            }
        }
    }
}

enum SpeakerColor {
    static func color(for key: String) -> Color {
        if key == "me" { return .accentColor }
        if key == "them" { return .purple }
        let palette: [Color] = [.orange, .purple, .teal, .pink, .green, .brown, .indigo, .red]
        let n = Int(key.dropFirst()) ?? 0
        return palette[n % palette.count]
    }
}

/// Speaker chips. Click one to give it a real name.
struct SpeakerBar: View {
    let meeting: Meeting
    let keys: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !keys.isEmpty {
                    Text("Speakers").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.self) { key in
                    SpeakerChip(meeting: meeting, key: key)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

struct SpeakerChip: View {
    @Environment(AppState.self) private var state
    let meeting: Meeting
    let key: String
    @State private var editing = false
    @State private var name = ""

    /// Lines can only move to another speaker once the final pass is done.
    private var canMerge: Bool {
        state.recordingID != meeting.id && state.finalizing[meeting.id] == nil
    }

    var body: some View {
        Button {
            name = meeting.speakerNames[key] ?? ""
            editing = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(SpeakerColor.color(for: key)).frame(width: 7, height: 7)
                Text(meeting.displayName(for: key))
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename speaker")
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name for \(meeting.displayName(for: key))").font(.headline)
                TextField("e.g. Anna", text: $name)
                    .frame(width: 220)
                    .onSubmit(save)
                HStack {
                    let others = meeting.speakerKeys.filter { $0 != key }
                    if canMerge && !others.isEmpty {
                        Menu("Same as…") {
                            ForEach(others, id: \.self) { other in
                                Button(meeting.displayName(for: other)) { merge(into: other) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Wrong split? Move all lines of this speaker to another one.")
                    }
                    Spacer()
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        state.renameSpeaker(key, to: name, in: meeting.id)
        editing = false
    }

    private func merge(into other: String) {
        editing = false
        state.mergeSpeaker(key, into: other, in: meeting.id)
    }
}
