//
//  GhosttyCommandRouting.swift
//  rootshell
//
//  Shared keys for command routing notifications
//

import Foundation

enum GhosttyCommandRouting {
    static let windowSceneSessionIDKey = "windowSceneSessionID"
    /// Marks Close Tab/Split notifications that came from a keyboard or menu
    /// command. Session-end notifications intentionally omit this key so they
    /// can tear down panes without presenting user confirmation UI.
    static let userInitiatedCloseSplitKey = "userInitiatedCloseSplit"
    static let paneCommandNotification = Notification.Name("com.rootshell.menuPaneCommand")
    static let paneCommandKey = "paneCommand"

    enum PaneCommand: Sendable {
        case clearScreen
        case scrollPageUp
        case scrollPageDown
        case scrollToTop
        case scrollToBottom
        case toggleCompose
        case toggleMouseCapture
        case cycleInputSource
    }
}
