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
    @Environment(\.sheetThemeColors) private var sheetThemeColors

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
                    guideRow(
                        icon: "text.viewfinder",
                        title: "On-Device Recognition",
                        description: "Detection reads each pane's title and visible screen on this device. Nothing is installed on the server."
                    )

                    Divider()

                    guideRow(
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
                    guideRow(
                        icon: "timer",
                        title: "Live Tab Status",
                        description: "Tabs show each agent's state: working with elapsed time, needs input, done, or failed."
                    )

                    Divider()

                    guideRow(
                        icon: "tray.full",
                        title: "Agent Inbox",
                        description: "The tab sidebar becomes an agent inbox with unread states. \"Done\" markers clear when you view the tab."
                    )

                    Divider()

                    guideRow(
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

    // MARK: - Helper Views

    private func guideRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationView {
        AgentDetectionGuideView()
    }
}
