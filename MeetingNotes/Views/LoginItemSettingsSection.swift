//
//  LoginItemSettingsSection.swift
//  Meeting Notes
//
//  Created by Philipp Hübl on 16.11.2026.
//

import SwiftUI

struct LoginItemSettingsSection: View {
    @State private var status = LoginItem.status
    @State private var errorText: String?

    var body: some View {
        LoginItemSettingsContent(
            status: status,
            errorText: errorText,
            setEnabled: setEnabled,
            openSystemSettings: LoginItem.openSystemSettings,
            refresh: { status = LoginItem.status }
        )
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        status = LoginItem.status
    }
}

private struct LoginItemSettingsContent: View {
    let status: LoginItem.Status
    let errorText: String?
    let setEnabled: (Bool) -> Void
    let openSystemSettings: () -> Void
    let refresh: () -> Void

    var body: some View {
        Section("Startup") {
            Toggle("Open Meeting Notes at login", isOn: Binding(get: { status != .off }, set: setEnabled))
                // The user can change the login item in System Settings while this window is open.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    refresh()
                }
            Text("Starts in the menu bar. The window stays closed until you open it.")
                .font(.caption).foregroundStyle(.secondary)
            if status == .needsApproval {
                HStack {
                    Text("Meeting Notes is turned off in the Login Items settings of your Mac.")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items Settings", action: openSystemSettings)
                }
            } else if let errorText {
                Text(errorText)
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    Form {
        LoginItemSettingsContent(status: .needsApproval, errorText: nil, setEnabled: { _ in },
                                 openSystemSettings: {}, refresh: {})
    }
    .formStyle(.grouped)
    .frame(width: 560)
}
