//
//  TaskDetectionSettingsView.swift
//  rootshell
//
//  Task-detection settings: the master switch, the per-family toggles, and
//  the notification policy. A separate feature from coding-agent detection
//  with its own switch; the two share one scan engine, so enabling either
//  runs it and enabling both costs no more than one.
//

import SwiftUI

struct TaskDetectionSettingsView: View {
    @Setting(Settings.Notifications.taskDetection) private var taskDetectionEnabled
    @Setting(Settings.Notifications.taskPolicy) private var taskNotificationPolicy

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Notifications.taskDetection, title: "Detect Long-Running Commands", icon: "clock.badge.checkmark") { enabled in
                    AgentAttentionCenter.shared.setTaskDetectionEnabled(enabled)
                }
                .themedRow()
            } footer: {
                Text("Recognizes builds, test runs, deployments, file transfers, and password or confirmation prompts in any tab by reading each pane's visible screen on this device. Works with or without agent detection; nothing is installed on the server. Very short runs on remote hosts may finish before they can be noticed.")
            }

            Section {
                familyToggle(.prompts, icon: "questionmark.key.filled",
                             title: "Input Prompts",
                             subtitle: "sudo, SSH host keys, y/n confirmations")
                familyToggle(.tests, icon: "checklist",
                             title: "Test Runs",
                             subtitle: "pytest, Jest, go test, cargo test, swift test")
                familyToggle(.builds, icon: "hammer",
                             title: "Builds",
                             subtitle: "Cargo, Ninja, xcodebuild")
                familyToggle(.infra, icon: "server.rack",
                             title: "Infrastructure",
                             subtitle: "Terraform, kubectl, Docker")
                familyToggle(.transfers, icon: "arrow.up.arrow.down.circle",
                             title: "File Transfers",
                             subtitle: "rsync, scp, curl, wget")
            } header: {
                SettingGroupHeader("What to Detect", group: .notifications)
            } footer: {
                Text("Detected commands appear as cards in the tab sidebar, the same way agents do, with a badge while running and an unread marker when they finish in a tab you aren't looking at.")
            }

            Section {
                NavigationLink {
                    TaskNotificationPolicyPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bell.and.waves.left.and.right")
                        Text("Command Notifications")
                        SettingPinTag(Settings.Notifications.taskPolicy.erased)
                        Spacer()
                        Text(taskNotificationPolicy.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .disabled(!taskDetectionEnabled)
                .themedRow()
                .settingContextMenu(Settings.Notifications.taskPolicy)
            } header: {
                SettingGroupHeader("Notifications", group: .notifications)
            } footer: {
                Text("Sidebar badges follow the \"Show Attention Badges\" switch in Coding Agents; notifications follow this policy independently of agent notifications.")
            }
        }
        .themedList()
        .navigationTitle("Command Detection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func familyToggle(
        _ family: TaskFamily,
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        FamilyToggleRow(family: family, icon: icon, title: title, subtitle: subtitle)
            .disabled(!taskDetectionEnabled)
    }
}

/// One family switch. Its own view so each row can hold the `@Setting`
/// for its family's key (stored properties can't be keyed dynamically).
private struct FamilyToggleRow: View {
    private let key: SettingKey<Bool>
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @Setting private var enabled: Bool

    init(family: TaskFamily, icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        let key = TaskDetectionSettings.familyKey(family)
        self.key = key
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        _enabled = Setting(key)
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            HStack(spacing: 12) {
                SettingsIcon(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .layoutPriority(1)
                        SettingPinTag(key.erased)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onChange(of: enabled) { _, _ in
            AgentAttentionCenter.shared.taskFamiliesChanged()
        }
        .themedRow()
        .settingContextMenu(key)
    }
}

// MARK: - Task Notification Policy Picker

struct TaskNotificationPolicyPickerView: View {
    @Setting(Settings.Notifications.taskPolicy) private var policy

    private var notificationsOff: Bool {
        policy == .off
    }

    var body: some View {
        List {
            Section {
                ForEach(TaskNotificationPolicy.allCases, id: \.rawValue) { option in
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
                Text("Notifications fire once per confirmed command event, only for tabs you aren't looking at. Each tab keeps one command notification alongside at most one agent notification; opening the tab clears them.")
            }

            Section {
                SettingToggle(Settings.Notifications.agentIncludePrompt, title: "Include the Prompt", icon: "text.bubble")
                    .disabled(notificationsOff)
                    .themedRow()
            } header: {
                SettingGroupHeader("Detail", group: .notifications)
            } footer: {
                Text("Quotes the waiting prompt (\"[sudo] password for …:\") in the notification. Shared with agent notifications: turn it off to keep terminal text off the Lock Screen.")
            }
        }
        .themedList()
        .navigationTitle("Command Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.notifications]) }
    }
}
