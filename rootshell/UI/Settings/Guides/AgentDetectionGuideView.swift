//
//  AgentDetectionGuideView.swift
//  rootshell
//
//  Explains how coding-agent detection works: what it recognizes, what runs
//  on-device, what the tab UI shows, and exactly what the optional project
//  and branch lookups send to connected hosts.
//

import SwiftUI

struct AgentDetectionGuideView: View {
    var body: some View {
        List {
            // MARK: - What It Detects
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recognizes coding agents running in any tab, locally or over SSH.")
                        .font(.subheadline)
                    Text("Claude Code, Codex, GitHub Copilot, Cursor, and more.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("What It Detects")
            }

            // MARK: - How It Works
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    GuideRow(
                        icon: "text.viewfinder",
                        title: "On-Device Recognition",
                        description: "Detection reads each pane's title and visible screen on this device. Nothing is installed on the server."
                    )

                    Divider()

                    GuideRow(
                        icon: "power",
                        title: "Zero Overhead When Off",
                        description: "Detect Coding Agents is the master switch. Off, the engine is fully stopped and adds no overhead."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("How It Works")
            }

            // MARK: - What You See
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    GuideRow(
                        icon: "timer",
                        title: "Live Tab Status",
                        description: "Tabs show each agent's state: working with elapsed time, needs input, done, or failed."
                    )

                    Divider()

                    GuideRow(
                        icon: "tray.full",
                        title: "Agent Inbox",
                        description: "The tab sidebar becomes an agent inbox with unread states. \"Done\" markers clear when you view the tab."
                    )

                    Divider()

                    GuideRow(
                        icon: "circlebadge.fill",
                        title: "Badges vs. Notifications",
                        description: "Show Attention Badges controls only the dots and cards. Notifications follow their own policy, chosen under Agent Notifications."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("What You See")
            }

            // MARK: - Project & Branch Lookups
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Look Up Project Details shows which project and branch each agent is working on. Because your repositories live on the machines you connect to, this runs a short read-only command there, asking tmux for a pane's directory or git for its branch, and only for tabs where an agent was detected.")
                        .font(.subheadline)
                    Text("While an agent remains active, a cached branch may be rechecked after five minutes on the next agent or visibility update. Lookups are batched per host and never open a new authenticated connection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Project & Branch Lookups")
            } footer: {
                Text("With the toggle off, no command is sent. The project is then shown only for hosts whose shell reports its directory on its own, and no branch is shown.")
            }
        }
        .themedList()
        .navigationTitle("How Detection Works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        AgentDetectionGuideView()
    }
}
