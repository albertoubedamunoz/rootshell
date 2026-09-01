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
    @Setting(Settings.CodingAgents.attentionBadges) private var attentionBadgesEnabled
    @Setting(Settings.CodingAgents.projectProbes) private var projectProbesEnabled
    @Setting(Settings.CodingAgents.usageTracking) private var usageTrackingEnabled
    @Setting(Settings.Notifications.agentPolicy) private var agentNotificationPolicy

    var body: some View {
        List {
            Section {
                Toggle(isOn: $agentDetectionEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "sparkles.rectangle.stack")
                        Text("Detect Coding Agents")
                    }
                }
                .onChange(of: agentDetectionEnabled) { _, enabled in
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
                Toggle(isOn: $attentionBadgesEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "circlebadge.fill")
                        Text("Show Attention Badges")
                    }
                }
                .themedRow()

                NavigationLink {
                    AgentNotificationPolicyPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bell.and.waves.left.and.right")
                        Text("Agent Notifications")
                        Spacer()
                        Text(agentNotificationPolicy.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .disabled(!agentDetectionEnabled)
                .themedRow()
            } header: {
                Text("Attention & Notifications")
            } footer: {
                Text("Badges control sidebar dots and cards for detected work and terminal-reported progress, even when coding-agent detection is off. Notifications follow their own policy; push notifications from paired computers always show. \"Done\" markers clear when you view the tab.")
            }

            Section {
                Toggle(isOn: $projectProbesEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "folder.badge.questionmark")
                        Text("Look Up Project Details")
                    }
                }
                .disabled(!agentDetectionEnabled)
                .onChange(of: projectProbesEnabled) { _, enabled in
                    AgentAttentionCenter.shared.setProjectProbesEnabled(enabled)
                }
                .themedRow()
            } header: {
                Text("Project Details")
            } footer: {
                Text("Shows each agent's project and branch by running a short read-only command on the connected host, only for tabs where an agent was detected. When off, nothing is sent; the branch is hidden and the project appears only when the shell reports it on its own.")
            }

            Section {
                Toggle(isOn: $usageTrackingEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "gauge.with.needle")
                        Text("Show Subscription Usage")
                    }
                }
                .disabled(!agentDetectionEnabled)
                .onChange(of: usageTrackingEnabled) { _, enabled in
                    AgentUsageCenter.shared.setEnabled(enabled)
                }
                .themedRow()
            } header: {
                Text("Subscription Usage")
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
    @Setting(Settings.Notifications.agentIncludePrompt) private var includePrompt

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
                Toggle(isOn: $includePrompt) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "text.bubble")
                        Text("Include the Question")
                    }
                }
                .disabled(notificationsOff)
                .themedRow()
            } header: {
                Text("Detail")
            } footer: {
                Text("Quotes what the agent is asking (\"Do you want to make this edit to …?\") in the notification. Turn this off to keep terminal text off the Lock Screen; notifications then show the project, branch, and how long the run took.")
            }
        }
        .themedList()
        .navigationTitle("Agent Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
