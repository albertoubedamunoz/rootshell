//
//  AgentNotificationContent.swift
//  rootshell
//
//  Composes the three lines of an agent-attention notification: who, where,
//  and what.
//
//  The rule that shapes everything here is that no line may repeat another.
//  A pane's tab title is DERIVED from its session-provided title, so the two
//  obvious sources for "where" and "what" are usually the same string, and
//  both usually contain the agent's own name, which the title already
//  carries. Each field therefore draws from an ordered candidate list and
//  takes the first entry that says something the notification does not say
//  already.
//
//  Pure: plain values in, three strings out. No UIKit, no isolation, no
//  monitor. Covered by tests/agent-attention.
//

import Foundation

nonisolated struct AgentNotificationContent: Equatable, Sendable {
    var title: String
    var subtitle: String
    var body: String

    /// Everything the router knows about a pane at delivery time. All of it
    /// is already resolved for the sidebar card; none of it used to reach
    /// the notification.
    nonisolated struct Context: Equatable, Sendable {
        var status: AgentAttentionStatus
        var category: AttentionCategory = .agent
        var agentName: String
        var projectLabel: String?
        var projectBranch: String?
        var tabTitle: String?
        var oscTitle: String?
        var connectionInfo: String?
        var workingSince: Date?
        var finishedAt: Date?
        var lastDuration: TimeInterval?
        var exitCode: Int?
        var backgroundAgentCount: Int = 0
        var promptSummary: String?

        init(
            status: AgentAttentionStatus,
            category: AttentionCategory = .agent,
            agentName: String,
            projectLabel: String? = nil,
            projectBranch: String? = nil,
            tabTitle: String? = nil,
            oscTitle: String? = nil,
            connectionInfo: String? = nil,
            workingSince: Date? = nil,
            finishedAt: Date? = nil,
            lastDuration: TimeInterval? = nil,
            exitCode: Int? = nil,
            backgroundAgentCount: Int = 0,
            promptSummary: String? = nil
        ) {
            self.status = status
            self.category = category
            self.agentName = agentName
            self.projectLabel = projectLabel
            self.projectBranch = projectBranch
            self.tabTitle = tabTitle
            self.oscTitle = oscTitle
            self.connectionInfo = connectionInfo
            self.workingSince = workingSince
            self.finishedAt = finishedAt
            self.lastDuration = lastDuration
            self.exitCode = exitCode
            self.backgroundAgentCount = backgroundAgentCount
            self.promptSummary = promptSummary
        }
    }

    static func make(_ context: Context, now: Date = Date()) -> AgentNotificationContent {
        let title = titleText(context)

        // Seeded with the title so nothing below can echo it. The agent's
        // own name needs no seed: `informationalKey` removes it from every
        // candidate, so a line that was only the name reduces to nothing
        // and is skipped as uninformative.
        var used: Set<String> = [informationalKey(title, agentName: context.agentName)]

        let subtitle = firstUsable(subtitleCandidates(context), context: context, used: &used)
        let body = firstUsable(bodyCandidates(context, now: now), context: context, used: &used)
        return AgentNotificationContent(title: title, subtitle: subtitle, body: body)
    }

    // MARK: - Title

    /// Who, and what state they are in. The state words match the sidebar
    /// card's own vocabulary so a glance at the banner and a glance at the
    /// inbox agree.
    private static func titleText(_ context: Context) -> String {
        let agent = context.agentName
        switch context.status {
        case .blocked:
            return String(localized: "\(agent) needs input",
                          comment: "Agent notification title: agent is waiting on the user")
        case .done:
            return String(localized: "\(agent) finished",
                          comment: "Agent notification title: agent completed its task")
        case .failed:
            if let code = context.exitCode, code != 0 {
                return String(localized: "\(agent) failed · exit \(code)",
                              comment: "Agent notification title: agent exited with a failure code")
            }
            return String(localized: "\(agent) failed",
                          comment: "Agent notification title: agent failed")
        case .working:
            if context.category == .task {
                return String(localized: "\(agent) is running",
                              comment: "Task notification title: command started running")
            }
            return String(localized: "\(agent) is working",
                          comment: "Agent notification title: agent started working")
        case .paused:
            return String(localized: "\(agent) is paused",
                          comment: "Agent notification title: activity is paused")
        case .idle:
            return String(localized: "\(agent) is idle",
                          comment: "Agent notification title: agent went idle")
        case .unknown:
            return agent
        }
    }

    // MARK: - Candidates

    /// Where the agent is. The project line is the same `project · branch`
    /// the sidebar card shows, so the banner names the work rather than the
    /// window.
    private static func subtitleCandidates(_ context: Context) -> [String?] {
        [projectLine(context), context.tabTitle, context.connectionInfo]
    }

    /// What is going on. The question comes first because for the one policy
    /// that is on by default (blocked only), it is the entire point of the
    /// notification.
    private static func bodyCandidates(_ context: Context, now: Date) -> [String?] {
        var candidates: [String?] = []
        if context.status == .blocked {
            candidates.append(context.promptSummary)
        }
        if context.status == .done || context.status == .failed {
            candidates.append(durationLine(context))
        }
        if context.status == .working {
            candidates.append(backgroundAgentLine(context))
            candidates.append(elapsedLine(context, now: now))
        }
        candidates.append(context.tabTitle)
        candidates.append(context.oscTitle)
        return candidates
    }

    static func projectLine(_ context: Context) -> String? {
        guard let label = context.projectLabel?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty
        else { return nil }
        guard let branch = context.projectBranch?.trimmingCharacters(in: .whitespaces),
              !branch.isEmpty
        else { return label }
        return "\(label) · \(branch)"
    }

    /// How long the finished run took. The OSC 133 duration is exact and is
    /// preferred; the working clock is the fallback for agents whose shell
    /// integration never reported a mark.
    private static func durationLine(_ context: Context) -> String? {
        let seconds: TimeInterval
        if let duration = context.lastDuration, duration > 0 {
            seconds = duration
        } else if let start = context.workingSince, let end = context.finishedAt, end > start {
            seconds = end.timeIntervalSince(start)
        } else {
            return nil
        }
        let elapsed = AgentElapsedFormat.elapsed(seconds: seconds)
        return String(localized: "Ran \(elapsed)",
                      comment: "Agent notification body: how long the finished run took")
    }

    private static func elapsedLine(_ context: Context, now: Date) -> String? {
        guard let start = context.workingSince, now > start else { return nil }
        let elapsed = AgentElapsedFormat.elapsed(from: start, to: now)
        return String(localized: "Working for \(elapsed)",
                      comment: "Agent notification body: how long the agent has been working")
    }

    /// Claude's fleet. Explicit branches rather than inflection markup: this
    /// type is compiled into the standalone harness, where the xcstrings
    /// machinery is absent.
    private static func backgroundAgentLine(_ context: Context) -> String? {
        let count = context.backgroundAgentCount
        guard count > 0 else { return nil }
        if count == 1 {
            return String(localized: "1 background agent still running",
                          comment: "Agent notification body: one sub-agent is still running")
        }
        return String(localized: "\(count) background agents still running",
                      comment: "Agent notification body: several sub-agents are still running")
    }

    // MARK: - Repetition

    private static func firstUsable(
        _ candidates: [String?],
        context: Context,
        used: inout Set<String>
    ) -> String {
        for candidate in candidates {
            guard let candidate else { continue }
            let text = AgentPromptSummary.collapseWhitespace(candidate)
            guard !text.isEmpty else { continue }
            let key = informationalKey(text, agentName: context.agentName)
            // An empty key means the candidate carried nothing the title did
            // not already say. An OSC title of "✳ Claude Code" against an
            // agent named "Claude Code" is exactly that.
            guard !key.isEmpty, !used.contains(key) else { continue }
            used.insert(key)
            return text
        }
        return ""
    }

    /// What a line actually tells the reader, stripped of everything that
    /// cannot distinguish it: case, decoration glyphs, punctuation, spacing,
    /// and the agent's own name.
    static func informationalKey(_ text: String, agentName: String) -> String {
        var stripped = text.lowercased()
        let name = agentName.lowercased().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            stripped = stripped.replacingOccurrences(of: name, with: " ")
        }
        let letters = stripped.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(letters).split(separator: " ").joined(separator: " ")
    }
}
