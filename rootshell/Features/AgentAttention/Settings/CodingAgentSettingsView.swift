//
//  CodingAgentSettingsView.swift
//  rootshell
//
//  Coding-agent detection settings: the master switch, attention badges, and
//  the notification policy. Detection runs on every terminal pane regardless
//  of connection type (local shell, SSH, mosh, tmux -CC windows), so this
//  lives under Terminal rather than with the multiplexer settings.
//

import SwiftUI

struct CodingAgentSettingsView: View {
    @Setting(Settings.CodingAgents.detectionEnabled) private var agentDetectionEnabled
    @Setting(Settings.Notifications.agentPolicy) private var agentNotificationPolicy

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.CodingAgents.detectionEnabled, title: "Detect Coding Agents", icon: "sparkles.rectangle.stack") { enabled in
                    AgentAttentionCenter.shared.setDetectionEnabled(enabled)
                }
                .themedRow()

                NavigationLink {
                    AgentDetectionGuideView()
                } label: {
                    Label("How Detection Works", systemImage: "questionmark.circle")
                }
                .themedRow()
            } footer: {
                Text("Recognizes coding agents (Claude Code, Codex, GitHub Copilot, Cursor, and more) in any tab by reading each pane's title and visible screen on this device. Nothing is installed on the server.")
            }

            Section {
                SettingToggle(Settings.CodingAgents.attentionBadges, title: "Show Attention Badges", icon: "circlebadge.fill")
                    .themedRow()

                NavigationLink {
                    AgentNotificationPolicyPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bell.and.waves.left.and.right")
                        Text("Agent Notifications")
                        SettingPinTag(Settings.Notifications.agentPolicy.erased)
                        Spacer()
                        Text(agentNotificationPolicy.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .disabled(!agentDetectionEnabled)
                .themedRow()
                .settingContextMenu(Settings.Notifications.agentPolicy)
            } header: {
                Text("Attention & Notifications")
            } footer: {
                Text("Badges control sidebar dots and cards for detected work and terminal-reported progress, even when coding-agent detection is off. Notifications follow their own policy; push notifications from paired computers always show. \"Done\" markers clear when you view the tab.")
            }

            Section {
                SettingToggle(Settings.CodingAgents.projectProbes, title: "Look Up Project Details", icon: "folder.badge.questionmark") { enabled in
                    AgentAttentionCenter.shared.setProjectProbesEnabled(enabled)
                }
                .disabled(!agentDetectionEnabled)
                .themedRow()
            } header: {
                SettingGroupHeader("Project Details", group: .codingAgents)
            } footer: {
                Text("Shows each agent's project and branch by running a short read-only command on the connected host, only for tabs where an agent was detected. When off, nothing is sent; the branch is hidden and the project appears only when the shell reports it on its own.")
            }

            Section {
                SettingToggle(Settings.CodingAgents.usageTracking, title: "Show Subscription Usage", icon: "gauge.with.needle") { enabled in
                    AgentUsageCenter.shared.setEnabled(enabled)
                }
                .disabled(!agentDetectionEnabled)
                .themedRow()
            } header: {
                SettingGroupHeader("Subscription Usage", group: .codingAgents)
            } footer: {
                Text("Shows how much of your Claude, Codex, or GitHub Copilot subscription allowance is used, at the bottom of the tab sidebar, for agents currently running in a tab. Reads the agent's own sign-in from the connected host and checks usage with its provider from this device, no more than once every 5 to 15 minutes per account depending on the provider. An oh-my-pi session is different: it is signed in to several providers at once, so it is asked for its own usage summary instead and every account it reports appears, including providers listed here. Nothing is written to the host, and an oh-my-pi sign-in is never read at all. Your sign-in is never saved on this device; only the usage figures, plan name, account label and their timestamps are kept, so the sidebar can fill in immediately at launch.")
            }
        }
        .themedList()
        .navigationTitle("Coding Agents")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Agent Notification Policy Picker (id=agent-attention)

struct AgentNotificationPolicyPickerView: View {
    @Setting(Settings.Notifications.agentPolicy) private var policy

    private var notificationsOff: Bool {
        policy == .off
    }

    var body: some View {
        List {
            Section {
                ForEach(AgentNotificationPolicy.allCases, id: \.rawValue) { option in
                    Button {
                        policy = option
                        // Selecting a live policy is the consent moment;
                        // without authorization nothing would ever fire.
                        if option != .off {
                            Task { _ = await NotificationManager.shared.requestPermissions() }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.iconName)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.displayName)
                                    .foregroundColor(.primary)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if policy == option {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                Text("Notifications fire once per confirmed agent event, only for tabs you aren't looking at. Each tab keeps a single notification: a newer status replaces the older one, and opening the tab clears it. Bells never notify and never mark a tab.")
            }

            Section {
                SettingToggle(Settings.Notifications.agentIncludePrompt, title: "Include the Question", icon: "text.bubble")
                    .disabled(notificationsOff)
                    .themedRow()
            } header: {
                SettingGroupHeader("Detail", group: .notifications)
            } footer: {
                Text("Quotes what the agent is asking (\"Do you want to make this edit to …?\") in the notification. Turn this off to keep terminal text off the Lock Screen; notifications then show the project, branch, and how long the run took.")
            }
        }
        .themedList()
        .navigationTitle("Agent Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.notifications]) }
    }
}
