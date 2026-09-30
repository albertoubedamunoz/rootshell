import Foundation

/// The session-wide metadata pushed by unmodified herdr 0.9.0. Geometry and
/// terminal IDs still come from the API snapshot when topology changes.
nonisolated struct HerdrEndpointMetadata: Decodable {
    let boot_id: String
    let revision: UInt64
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]
    /// Records keyed by pane ID, built once so per-pane lookups stay linear.
    let panesByID: [String: Pane]
    let agentsByPaneID: [String: Agent]

    /// Stock shell snapshots omit titles for panes outside the agent list.
    /// Keep the slow API refresh for those panes, including hidden shells.
    let needsShellTitleRefresh: Bool

    /// Far above any real session; bounds work done on the main actor.
    static let recordLimit = 4096

    private enum CodingKeys: String, CodingKey {
        case boot_id, revision, workspaces, tabs, panes, agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boot_id = try container.decode(String.self, forKey: .boot_id)
        revision = try container.decode(UInt64.self, forKey: .revision)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        panes = try container.decode([Pane].self, forKey: .panes)
        agents = try container.decode([Agent].self, forKey: .agents)
        let limit = Self.recordLimit
        guard workspaces.count <= limit, tabs.count <= limit, panes.count <= limit, agents.count <= limit else {
            throw DecodingError.dataCorruptedError(forKey: .panes, in: container,
                debugDescription: "endpoint metadata exceeds \(limit) records")
        }
        var panesByID: [String: Pane] = [:]
        var agentsByPaneID: [String: Agent] = [:]
        for pane in panes where panesByID.updateValue(pane, forKey: pane.pane_id) != nil {
            throw DecodingError.dataCorruptedError(forKey: .panes, in: container,
                debugDescription: "duplicate pane \(pane.pane_id)")
        }
        for agent in agents where agentsByPaneID.updateValue(agent, forKey: agent.pane_id) != nil {
            throw DecodingError.dataCorruptedError(forKey: .agents, in: container,
                debugDescription: "duplicate agent pane \(agent.pane_id)")
        }
        self.panesByID = panesByID
        self.agentsByPaneID = agentsByPaneID
        needsShellTitleRefresh = panes.contains { pane in
            agentsByPaneID[pane.pane_id].map { !$0.belongs(to: pane) } ?? true
        }
    }

    struct Workspace: Decodable, Equatable {
        let workspace_id: String
        let number: Int
        let label: String
    }

    struct Tab: Decodable, Equatable {
        let tab_id: String
        let workspace_id: String
        let number: Int
        let zoomed: Bool
    }

    struct Pane: Decodable, Equatable {
        let pane_id: String
        let workspace_id: String
        let tab_id: String
        let cwd: String?
        let foreground_cwd: String?

        func matches(_ info: HerdrControl.PaneInfo) -> Bool {
            pane_id == info.pane_id && workspace_id == info.workspace_id && tab_id == info.tab_id
        }

        func updatingDirectories(in info: HerdrControl.PaneInfo) -> HerdrControl.PaneInfo {
            guard matches(info) else { return info }
            var updated = info
            updated.cwd = cwd
            updated.foreground_cwd = foreground_cwd
            return updated
        }
    }

    struct Agent: Decodable {
        let pane_id: String
        let workspace_id: String
        let tab_id: String
        let agent: String?
        let display_agent: String?
        let title: String?
        let terminal_title: String?
        let terminal_title_stripped: String?
        let agent_status: String
        let state_labels: [[String]]

        func belongs(to pane: Pane) -> Bool {
            pane_id == pane.pane_id && workspace_id == pane.workspace_id && tab_id == pane.tab_id
        }

        var report: HerdrControl.AgentStatusChangedData {
            .init(pane_id: pane_id, workspace_id: workspace_id,
                  agent_status: agent_status, agent: agent, title: title,
                  display_agent: display_agent, state_labels: Dictionary(
                    state_labels.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
                    uniquingKeysWith: { _, latest in latest }))
        }

        // Vanilla deliberately suppresses spinner-only title events. Use its
        // semantic title so a sampled braille glyph does not look frozen.
        var reportedTitle: String? { terminal_title_stripped ?? title ?? terminal_title }
    }

    func report(for info: HerdrControl.PaneInfo) -> HerdrControl.AgentStatusChangedData? {
        guard let pane = pane(matching: info) else { return nil }
        if let agent = agentsByPaneID[pane.pane_id], agent.belongs(to: pane) { return agent.report }
        return .init(pane_id: info.pane_id, workspace_id: info.workspace_id,
            agent_status: "unknown", agent: nil, title: nil, display_agent: nil, state_labels: nil)
    }

    func pane(matching info: HerdrControl.PaneInfo) -> Pane? {
        panesByID[info.pane_id].flatMap { $0.matches(info) ? $0 : nil }
    }

    func hasSameTopology(as other: Self) -> Bool {
        boot_id == other.boot_id && workspaces == other.workspaces
            && tabs == other.tabs && panes.count == other.panes.count
            && zip(panes, other.panes).allSatisfy {
                $0.pane_id == $1.pane_id && $0.workspace_id == $1.workspace_id && $0.tab_id == $1.tab_id
            }
    }
}
