import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    @AppStorage(Prefs.Key.model) private var model = WhisperModelOption.all[0].id
    @AppStorage(Prefs.Key.language) private var language = TranscriptionLanguage.auto.rawValue
    @AppStorage(Prefs.Key.keepAudio) private var keepAudio = false
    @AppStorage(Prefs.Key.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(Prefs.Key.autoSummarize) private var autoSummarize = true
    @AppStorage(Prefs.Key.notesFolder) private var notesFolder = ""
    @AppStorage(Prefs.Key.claudePath) private var claudePath = ""
    @AppStorage(Prefs.Key.claudeModel) private var claudeModel = ""

    @State private var detectedClaude: String?

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Whisper model", selection: $model) {
                    ForEach(WhisperModelOption.all) { Text($0.label).tag($0.id) }
                }
                .onChange(of: model) { state.prepareModel() }
                Picker("Language", selection: $language) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                ModelStatusView()
            }

            Section("Audio") {
                Toggle("Capture call audio (Zoom, Teams, Meet, …)", isOn: $captureSystemAudio)
                Text("Call capture records all sound your Mac plays. Tell the others that you are recording.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep audio files after transcription", isOn: $keepAudio)
                Text(keepAudio
                     ? "Audio moves into the meeting folder after the final transcript. You can transcribe again later."
                     : "Audio is stored outside your notes folder while recording and deleted after the final transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Files") {
                LabeledContent("Notes folder") {
                    HStack {
                        Text(Prefs.notesFolder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                            .disabled(state.isBusy)
                    }
                }
                if state.isBusy {
                    Text("You can change the folder once recording, transcript and summary are finished.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude") {
                Toggle("Summarize automatically after each meeting", isOn: $autoSummarize)
                Text("Claude writes the summary, so the transcript is sent to Anthropic when you summarize.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Model (empty = CLI default)", text: $claudeModel, prompt: Text("e.g. sonnet, opus"))
                TextField("CLI path (empty = auto-detect)", text: $claudePath, prompt: Text(detectedClaude ?? "not found"))
                if detectedClaude == nil && claudePath.isEmpty {
                    Text("Claude CLI not found. Install Claude Code and log in with `claude`.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { detectedClaude = await Task.detached { ClaudeRunner.findClaude() }.value }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.notesFolder
        if panel.runModal() == .OK, let url = panel.url {
            state.setNotesFolder(url)
        }
    }
}
