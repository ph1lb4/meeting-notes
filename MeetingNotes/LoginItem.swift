//
//  LoginItem.swift
//  Meeting Notes
//
//  Created by Philipp Hübl on 16.11.2026.
//

import AppKit
import ServiceManagement

/// The app as a login item. macOS keeps the state, so a change in System Settings shows up here too.
enum LoginItem {
    enum Status: Equatable {
        case off
        case on
        /// Registered, but turned off in System Settings > General > Login Items.
        case needsApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when macOS started the app as a login item. Only valid while the app finishes launching.
    static var startedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
