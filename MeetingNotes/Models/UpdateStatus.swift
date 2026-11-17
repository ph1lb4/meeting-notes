//
//  UpdateStatus.swift
//  Meeting Notes
//
//  Created by Philipp Hübl on 16.11.2026.
//

import Foundation

enum UpdateStatus: Equatable {
    case notSetUp
    case idle
    case checking
    case upToDate
    case available(version: String)
    case failed(String)

    var text: String {
        switch self {
        case .notSetUp: "Updates are not set up in this build."
        case .idle: "Not checked yet."
        case .checking: "Checking…"
        case .upToDate: "You're on the latest version."
        case .available(let version): "Version \(version) is available."
        case .failed(let message): "Could not check for updates. \(message)"
        }
    }

    /// A build without a public key or feed URL must never start the updater.
    static func isSetUp(publicKey: String?, feedURL: String?) -> Bool {
        func hasText(_ value: String?) -> Bool {
            !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText(publicKey) && hasText(feedURL)
    }

    /// Sparkle may show a scheduled update at once only when it would take focus anyway and no meeting runs.
    static func showsScheduledUpdateNow(immediateFocus: Bool, busy: Bool) -> Bool {
        immediateFocus && !busy
    }
}
