//
//  AgentInboxPreviews.swift
//  SessionActivityWidget
//
//  Xcode canvas previews for the four Live Activity forms of the agent inbox,
//  so the layout can be checked without staging a real hook push. Debug only:
//  previews never ship.
//

#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

private enum InboxPreviewData {
    static let now = Date()

    static func item(_ index: Int, agent: String, status: String) -> AgentInboxItem {
        AgentInboxItem(
            id: "preview-\(index)",
            agent: agent,
            status: status,
            at: now.addingTimeInterval(-Double(index) * 120),
            deepLink: URL(string: "rootshell://pane/00000000-0000-0000-0000-00000000000\(index)")!
        )
    }

    /// Three agents, one blocked, one overflow row — the shape §6 describes.
    static var state: SessionActivityAttributes.ContentState {
        SessionActivityAttributes.ContentState(
            sessionCount: 2,
            sshCount: 1,
            k8sCount: 0,
            consoleCount: 1,
            hostNames: ["prod-web-01"],
            lastUpdated: now,
            agentItems: [
                item(0, agent: "codex", status: "done"),
                item(1, agent: "claude", status: "blocked"),
                item(2, agent: "pi", status: "failed"),
                item(3, agent: "claude", status: "done"),
                item(4, agent: "omp", status: "done"),
            ],
            agentUnreadTotal: 7
        )
    }

    /// Sessions only: the pre-existing island, unchanged.
    static var sessionOnly: SessionActivityAttributes.ContentState {
        SessionActivityAttributes.ContentState(
            sessionCount: 2,
            sshCount: 1,
            k8sCount: 0,
            consoleCount: 1,
            hostNames: ["prod-web-01"],
            lastUpdated: now
        )
    }
}

#Preview("Inbox · Lock Screen", as: .content, using: SessionActivityAttributes()) {
    SessionActivityWidget()
} contentStates: {
    InboxPreviewData.state
}

#Preview("Inbox · Compact", as: .dynamicIsland(.compact), using: SessionActivityAttributes()) {
    SessionActivityWidget()
} contentStates: {
    InboxPreviewData.state
}

#Preview("Inbox · Minimal", as: .dynamicIsland(.minimal), using: SessionActivityAttributes()) {
    SessionActivityWidget()
} contentStates: {
    InboxPreviewData.state
}

#Preview("Inbox · Expanded (3 rows + fold)", as: .dynamicIsland(.expanded), using: SessionActivityAttributes()) {
    SessionActivityWidget()
} contentStates: {
    InboxPreviewData.state
}

#Preview("Session island · unchanged", as: .dynamicIsland(.expanded), using: SessionActivityAttributes()) {
    SessionActivityWidget()
} contentStates: {
    InboxPreviewData.sessionOnly
}
#endif
