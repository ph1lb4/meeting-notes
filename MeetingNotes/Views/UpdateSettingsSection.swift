//
//  UpdateSettingsSection.swift
//  Meeting Notes
//
//  Created by Philipp Hübl on 16.11.2026.
//

import SwiftUI

struct UpdateSettingsSection: View {
    private let updater = AppUpdater.shared

    var body: some View {
        UpdateSettingsContent(
            status: updater.status,
            lastChecked: updater.lastChecked,
            canCheck: updater.canCheck,
            isSetUp: updater.isSetUp,
            automaticChecks: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }),
            checkNow: updater.checkNow
        )
    }
}

private struct UpdateSettingsContent: View {
    let status: UpdateStatus
    let lastChecked: Date?
    let canCheck: Bool
    let isSetUp: Bool
    @Binding var automaticChecks: Bool
    let checkNow: () -> Void

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: Self.version)
            if status != .idle {
                LabeledContent("Status") { StatusLabel(text: status.text, color: statusColor) }
            }
            if isSetUp {
                Toggle("Check for updates automatically", isOn: $automaticChecks)
            }
            HStack {
                Button("Check Now", action: checkNow)
                    .disabled(!canCheck)
                Spacer()
                if let lastChecked {
                    Text("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .upToDate: .green
        case .available: .orange
        case .failed: .red
        case .notSetUp, .idle, .checking: .secondary
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    Form {
        UpdateSettingsContent(status: .upToDate, lastChecked: .now, canCheck: true, isSetUp: true,
                              automaticChecks: .constant(true), checkNow: {})
    }
    .formStyle(.grouped)
    .frame(width: 560)
}
