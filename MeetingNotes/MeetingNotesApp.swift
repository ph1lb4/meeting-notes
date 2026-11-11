import SwiftUI

@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: AppState

    init() {
        SelfTest.runIfRequested()
        let state = AppState()
        _state = State(initialValue: state)
        AppDelegate.state = state
    }

    var body: some Scene {
        Window("Meeting Notes", id: "main") {
            MainView()
                .environment(state)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button(state.isRecording ? "Stop Recording" : "Start Recording") { state.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environment(state)
        } label: {
            Image(systemName: state.isRecording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView().environment(state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.state else { return .terminateNow }
        let alert = NSAlert()
        if state.isRecording {
            alert.messageText = "A meeting is still being recorded"
            alert.informativeText = "Stop the recording first to get the full transcript. If you quit now, the recording ends and the transcript is finished the next time you open Meeting Notes."
            alert.addButton(withTitle: "Keep Recording")
        } else if !state.finalizing.isEmpty {
            alert.messageText = "A transcript is still being finished"
            alert.informativeText = "This usually takes a few minutes. If you quit now, the final transcript is written the next time you open Meeting Notes."
            alert.addButton(withTitle: "Keep Working")
        } else {
            return .terminateNow
        }
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close a running recording and write pending changes before the process exits.
        Self.state?.prepareForTermination()
    }
}
