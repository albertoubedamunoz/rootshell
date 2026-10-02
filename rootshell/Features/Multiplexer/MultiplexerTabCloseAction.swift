//
//  MultiplexerTabCloseAction.swift
//  rootshell
//
//  What CMD-W / the tab "X" does when closing a tmux control-mode (-CC)
//  window tab or a herdr control-mode tab. Global preference, surfaced in
//  Settings → Terminal → Tabs and Settings → Connections → Multiplexers → Tabs.
//  Default preserves the historical behavior (close it on the server).
//  (id=tmux-tab-close-action)
//

import Foundation

enum MultiplexerTabCloseAction: String, CaseIterable, Codable, Sendable {
    /// Destroy the tmux window (`kill-window`) or herdr tab (`tab.close`)
    /// on the server. Default — the only behavior before this setting existed.
    case closeWindow

    /// Gracefully detach the whole session for this gateway. Everything
    /// keeps running on the server; the gateway tab returns to its shell.
    case detachSession

    /// Graceful detach, then also close the gateway tab once control mode
    /// tears down — fully leave the multiplexer. Session survives on the server.
    case detachSessionAndCloseGateway

    /// UI-only hide of a tmux tab (the window stays alive on the server).
    /// herdr has no hide and detaches instead.
    case hideTab

    /// Prompt with an action sheet on every close.
    case ask

    /// The user's current preference, defaulting to `.closeWindow`.
    static var current: MultiplexerTabCloseAction {
        SettingsStore.shared.value(Settings.Multiplexer.tabCloseAction)
    }

    var displayName: String {
        switch self {
        case .closeWindow: return "Close on Server"
        case .detachSession: return "Detach Session"
        case .detachSessionAndCloseGateway: return "Detach & Close Gateway"
        case .hideTab: return "Hide Tab"
        case .ask: return "Ask Each Time"
        }
    }

    /// Longer explanation shown beneath the title in the picker list.
    var detail: String {
        switch self {
        case .closeWindow:
            return "Close the tmux window or herdr tab on the host. Anything running in it is terminated."
        case .detachSession:
            return "Leave the whole session running on the host and return the gateway tab to its shell."
        case .detachSessionAndCloseGateway:
            return "Detach the session (it keeps running on the host), then also close the gateway tab."
        case .hideTab:
            return "Hide the tab locally. The tmux window keeps running and can be shown again later. herdr tabs detach instead."
        case .ask:
            return "Prompt with these choices every time you close a tmux or herdr control-mode tab."
        }
    }

    var iconName: String {
        switch self {
        case .closeWindow: return "xmark.rectangle"
        case .detachSession: return "eject"
        case .detachSessionAndCloseGateway: return "eject.fill"
        case .hideTab: return "eye.slash"
        case .ask: return "questionmark.circle"
        }
    }
}
