import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SummarySettings()
                .tabItem { Label("Summary", systemImage: "sparkles") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    @AppStorage(Prefs.Key.model) private var model = WhisperModelOption.all[0].id
    @AppStorage(Prefs.Key.language) private var language = TranscriptionLanguage.auto.rawValue
    @AppStorage(Prefs.Key.keepAudio) private var keepAudio = false
    @AppStorage(Prefs.Key.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(Prefs.Key.autoStopOnCallEnd) private var autoStopOnCallEnd = true
    @AppStorage(Prefs.Key.notesFolder) private var notesFolder = ""
    @AppStorage(Prefs.Key.micDeviceUID) private var micDeviceUID = ""
    @AppStorage(Prefs.Key.vocabulary) private var vocabulary = ""
    @AppStorage(Prefs.Key.cleanupTranscript) private var cleanupTranscript = true
    @State private var inputDevices = AudioInputDeviceList()

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Whisper model", selection: $model) {
                    ForEach(WhisperModelOption.all) { option in
                        Text(Prefs.isWhisperModelDownloaded(option.id) ? "\(option.label) · downloaded" : option.label)
                            .tag(option.id)
                    }
                }
                .onChange(of: model) { state.prepareModel() }
                Picker("Language", selection: $language) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if language == TranscriptionLanguage.auto.rawValue {
                    Text("Auto finds the main language of each speaker track and sticks to it, so lines are not translated by mistake.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Vocabulary", text: $vocabulary, prompt: Text("Names, products, terms"), axis: .vertical)
                    .lineLimit(2...4)
                Text("Comma separated. Claude uses it to spell names and terms right in the transcript and summary.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fix misheard words with Claude", isOn: $cleanupTranscript)
                Text("After each meeting, Claude corrects words, names and terms in the transcript. The transcript is sent to Anthropic, like for the summary. Off with \"Apple Intelligence only\".")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status") { WhisperStatusText() }
                ModelStatusView()
                Text("Transcription and speaker detection run on this Mac. Models are stored in Application Support.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Microphone", selection: $micDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices.devices) { Text($0.name).tag($0.uid) }
                    if !micDeviceUID.isEmpty, !inputDevices.devices.contains(where: { $0.uid == micDeviceUID }) {
                        Text("Not connected").tag(micDeviceUID)
                    }
                }
                if !micDeviceUID.isEmpty, !inputDevices.devices.contains(where: { $0.uid == micDeviceUID }) {
                    Text("This microphone is not connected. The system default is used until it is back.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if state.isRecording {
                    Text("A new microphone is used from the next recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Capture call audio (Zoom, Teams, Meet, …)", isOn: $captureSystemAudio)
                Text("Call capture records all sound your Mac plays. Tell the others that you are recording.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Stop recording when the call ends", isOn: $autoStopOnCallEnd)
                Text("Stops about 10 seconds after your call app lets go of the microphone and the call goes quiet.")
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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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

private struct WhisperStatusText: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.modelStatus {
        case .ready: StatusLabel(text: "Loaded and ready", color: .green)
        case .idle: StatusLabel(text: "Not loaded. Loads when you record.", color: .secondary)
        case .downloading(let p): StatusLabel(text: "Downloading \(Int(p * 100)) %", color: .orange)
        case .loading: StatusLabel(text: "Loading…", color: .orange)
        case .failed: StatusLabel(text: "Failed", color: .red)
        }
    }
}

// MARK: - Summary

private struct SummarySettings: View {
    @Environment(AppState.self) private var state

    @AppStorage(Prefs.Key.summaryEngine) private var engineChoice = SummaryEngineChoice.auto.rawValue
    @AppStorage(Prefs.Key.autoSummarize) private var autoSummarize = true
    @AppStorage(Prefs.Key.claudePath) private var claudePath = ""
    @AppStorage(Prefs.Key.claudeModel) private var claudeModel = ""

    @State private var checking = false
    @State private var claudeTest: TestResult?
    @State private var appleTest: TestResult?

    private var choice: SummaryEngineChoice { SummaryEngineChoice(rawValue: engineChoice) ?? .auto }

    var body: some View {
        Form {
            Section("Summary") {
                LabeledContent("Writes summaries now") { activeEngine }
                Picker("Engine", selection: $engineChoice) {
                    ForEach(SummaryEngineChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                Toggle("Summarize automatically after each meeting", isOn: $autoSummarize)
            }

            claudeSection
            appleSection
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refresh() }
        .onChange(of: engineChoice) { Task { await refresh() } }
        .onChange(of: claudePath) { Task { await refresh() } }
    }

    // MARK: Overview

    @ViewBuilder
    private var activeEngine: some View {
        if !state.enginesChecked || checking {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        } else if let engine = state.availableEngine {
            StatusLabel(text: engine.label + (engine == .apple && choice == .auto ? " (Claude Code not found)" : ""),
                        color: .green)
        } else {
            StatusLabel(text: "Nothing available", color: .red)
        }
    }

    // MARK: Claude

    private var claudeSection: some View {
        Section {
            LabeledContent("Status") { claudeStatus }
            if let path = state.claudeCLI {
                LabeledContent("Location") {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
                if ClaudeRunner.isDesktopAppCopy(path) {
                    Text("This is the copy inside the Claude desktop app. It can stop working when that app updates. Installing Claude Code is more reliable.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if state.enginesChecked {
                installHelp
            }
            LabeledContent("Model") {
                TextField("Model", text: $claudeModel, prompt: Text("CLI default"))
                    .labelsHidden().frame(width: 200)
            }
            Text("Leave empty for your Claude Code default, or enter e.g. sonnet or opus.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Custom path") {
                TextField("Custom path", text: $claudePath, prompt: Text("Auto-detect"))
                    .labelsHidden().frame(width: 280)
            }
            HStack {
                Button("Check Again") { Task { await refresh() } }
                Button("Test Claude") { runClaudeTest() }
                    .disabled(state.claudeCLI == nil || claudeTest == .running)
                Spacer()
                TestResultView(result: claudeTest)
            }
            Text("Claude summaries send the transcript and your notes to Anthropic.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Claude Code")
        }
    }

    @ViewBuilder
    private var claudeStatus: some View {
        if !state.enginesChecked {
            Text("Checking…").foregroundStyle(.secondary)
        } else if let path = state.claudeCLI {
            let version = state.claudeVersion.map { " · v\($0)" } ?? ""
            StatusLabel(text: (ClaudeRunner.isDesktopAppCopy(path) ? "Found in Claude app" : "Installed") + version,
                        color: ClaudeRunner.isDesktopAppCopy(path) ? .orange : .green)
        } else if !claudePath.isEmpty {
            StatusLabel(text: "Nothing runnable at the custom path", color: .red)
        } else {
            StatusLabel(text: "Not installed", color: .red)
        }
    }

    private var installHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install Claude Code to get the best summaries. You need a Claude Pro or Max plan, or an API account.")
                .font(.callout)
            Text("1. Open Terminal and run:").font(.callout)
            HStack {
                Text(ClaudeRunner.installCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Button {
                    state.copyToClipboard(ClaudeRunner.installCommand)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Text("2. Run `claude` once and log in.").font(.callout)
            Text("3. Come back and click Check Again.").font(.callout)
            Link("Installation guide", destination: ClaudeRunner.installGuideURL).font(.callout)
        }
        .padding(.vertical, 4)
    }

    // MARK: Apple Intelligence

    private var appleSection: some View {
        Section {
            LabeledContent("Status") {
                StatusLabel(text: appleStatusText, color: state.appleIntelligence == .available ? .green : .secondary)
            }
            if state.appleIntelligence != .available {
                Text(state.appleIntelligence.message).font(.caption).foregroundStyle(.secondary)
            }
            if state.appleIntelligence == .notEnabled {
                Button("Open Apple Intelligence Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            HStack {
                Button("Test Apple Intelligence") { runAppleTest() }
                    .disabled(state.appleIntelligence != .available || appleTest == .running)
                Spacer()
                TestResultView(result: appleTest)
            }
            Text("Runs on this Mac, nothing leaves it. Long meetings are summarized in parts, so expect shorter notes than with Claude.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Apple Intelligence")
        }
    }

    private var appleStatusText: String {
        switch state.appleIntelligence {
        case .available: return "Ready"
        case .notEnabled: return "Turned off"
        case .notReady: return "Downloading"
        case .notEligible: return "Not supported on this Mac"
        case .unsupportedOS: return "Needs macOS 26"
        }
    }

    // MARK: Actions

    private func refresh() async {
        checking = true
        await state.refreshSummaryEngines()
        checking = false
    }

    private func runClaudeTest() {
        guard let path = state.claudeCLI else { return }
        claudeTest = .running
        Task {
            do {
                let answer = try await ClaudeRunner.test(at: path)
                claudeTest = answer.isEmpty ? .failed("Empty answer. Run `claude` in Terminal and log in.") : .ok
            } catch {
                claudeTest = .failed(error.localizedDescription + " Run `claude` in Terminal to check the login.")
            }
        }
    }

    private func runAppleTest() {
        appleTest = .running
        Task {
            do {
                _ = try await AppleSummarizer.test()
                appleTest = .ok
            } catch {
                appleTest = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Small parts

private enum TestResult: Equatable {
    case running, ok, failed(String)
}

private struct TestResultView: View {
    let result: TestResult?

    var body: some View {
        switch result {
        case .none: EmptyView()
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…").foregroundStyle(.secondary) }
        case .ok: StatusLabel(text: "Works", color: .green)
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                StatusLabel(text: "Failed", color: .red)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).lineLimit(4).textSelection(.enabled)
            }
            .frame(maxWidth: 300, alignment: .trailing)
        }
    }
}

struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}
