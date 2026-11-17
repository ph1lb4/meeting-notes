import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.isRecording {
            ElapsedText(prefix: "Recording · ")
            Button("Stop Recording") { state.stopRecording() }
        } else {
            Button("Start Recording") {
                state.startRecording()
                showWindow()
            }
        }
        if !state.finalizing.isEmpty {
            Text("Finishing transcript…")
        }
        if !state.summarizing.isEmpty {
            Text("Writing summary…")
        }
        Divider()
        Button("Open Meeting Notes") { showWindow() }
        if !state.meetings.isEmpty {
            Menu("Recent") {
                ForEach(state.meetings.prefix(8)) { m in
                    Button(m.title) {
                        state.selectedID = m.id
                        showWindow()
                    }
                }
            }
        }
        Divider()
        Button(updateTitle) { AppUpdater.shared.checkNow() }
            .disabled(!AppUpdater.shared.canCheck)
        SettingsLink { Text("Settings…") }
        Button("Quit Meeting Notes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var updateTitle: String {
        if case .available(let version) = AppUpdater.shared.status { return "Install Version \(version)…" }
        return "Check for Updates…"
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
