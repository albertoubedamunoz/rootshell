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
    @AppStorage(TaskDetectionSettings.enabledKey)
    private var taskDetectionEnabled = false
    @AppStorage(TaskNotificationPolicy.storageKey)
    private var taskNotificationPolicy = TaskNotificationPolicy.blockedOnly.rawValue

    var body: some View {
        List {
            Section {
                Toggle(isOn: $taskDetectionEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "clock.badge.checkmark")
                        Text("Detect Long-Running Commands")
                    }
                }
                .onChange(of: taskDetectionEnabled) { _, enabled in
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
                Text("What to Detect")
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
                        Spacer()
                        Text((TaskNotificationPolicy(rawValue: taskNotificationPolicy) ?? .blockedOnly).displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .disabled(!taskDetectionEnabled)
                .themedRow()
            } header: {
                Text("Notifications")
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

/// One family switch. Its own view so each row can hold the `@AppStorage`
/// for its family's key (stored properties can't be keyed dynamically).
private struct FamilyToggleRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @AppStorage private var enabled: Bool

    init(family: TaskFamily, icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        _enabled = AppStorage(wrappedValue: true, TaskDetectionSettings.familyKey(family))
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            HStack(spacing: 12) {
                SettingsIcon(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
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
    }
}

// MARK: - Task Notification Policy Picker

struct TaskNotificationPolicyPickerView: View {
    @AppStorage(TaskNotificationPolicy.storageKey)
    private var policy = TaskNotificationPolicy.blockedOnly.rawValue
    @AppStorage(AgentAttentionSettings.notificationPromptEnabledKey)
    private var includePrompt = true

    private var notificationsOff: Bool {
        (TaskNotificationPolicy(rawValue: policy) ?? .blockedOnly) == .off
    }

    var body: some View {
        List {
            Section {
                ForEach(TaskNotificationPolicy.allCases, id: \.rawValue) { option in
                    Button {
                        policy = option.rawValue
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
                            if policy == option.rawValue {
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
                Toggle(isOn: $includePrompt) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "text.bubble")
                        Text("Include the Prompt")
                    }
                }
                .disabled(notificationsOff)
                .themedRow()
            } header: {
                Text("Detail")
            } footer: {
                Text("Quotes the waiting prompt (\"[sudo] password for …:\") in the notification. Shared with agent notifications: turn it off to keep terminal text off the Lock Screen.")
            }
        }
        .themedList()
        .navigationTitle("Command Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
