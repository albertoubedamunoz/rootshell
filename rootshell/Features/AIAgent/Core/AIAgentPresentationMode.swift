#if !CHINA_BUILD
//
//  AIAgentPresentationMode.swift
//  rootshell
//
//  Presentation mode enum for AI Agent on iPad/Mac Catalyst
//

import Foundation

/// Presentation mode for AI Agent on iPad/Mac Catalyst
/// iPhone always uses sheet presentation regardless of this setting
enum AIAgentPresentationMode: String, Codable, CaseIterable, Sendable {
    /// Side panel within the tab view with draggable resize divider
    case sidebar = "sidebar"

    /// Dedicated window that can display multiple sessions with a picker
    case window = "window"

    var displayName: String {
        switch self {
        case .sidebar: return String(localized: "Sidebar", comment: "AI Agent presentation mode: sidebar panel")
        case .window: return String(localized: "Separate Window", comment: "AI Agent presentation mode: dedicated window")
        }
    }

    var description: String {
        switch self {
        case .sidebar: return String(localized: "Show AI Agent as a side panel within each tab", comment: "AI Agent sidebar mode description")
        case .window: return String(localized: "Show AI Agent in a dedicated window", comment: "AI Agent window mode description")
        }
    }

    var icon: String {
        switch self {
        case .sidebar: return "sidebar.right"
        case .window: return "macwindow.on.rectangle"
        }
    }
}

// MARK: - Mode Switch Notification

extension Notification.Name {
    /// Posted when user requests to switch AI Agent presentation mode
    /// Object: AIAgentSwitchModeRequest
    static let aiAgentSwitchMode = Notification.Name("aiAgentSwitchMode")
}

/// Request to switch AI Agent presentation mode
struct AIAgentSwitchModeRequest {
    let tabID: UUID
    let targetMode: AIAgentPresentationMode
}
#endif
