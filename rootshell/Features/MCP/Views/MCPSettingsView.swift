//
//  MCPSettingsView.swift
//  rootshell
//
//  Settings view for MCP server configuration
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import SwiftUI

struct MCPSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var server = MCPServer.shared
    @State private var showYOLOWarning = false
    @State private var pendingYOLOConfirm = false

    var body: some View {
        List {
            serverSection
            securityModeSection
            sessionsSection
            cliCommandsSection
        }
        .themedList()
        .navigationTitle("MCP Server")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Enable YOLO Mode?", isPresented: $showYOLOWarning) {
            Button("Cancel", role: .cancel) {
                pendingYOLOConfirm = false
            }
            Button("Enable", role: .destructive) {
                server.config.sessionMode = .yolo
                pendingYOLOConfirm = false
            }
        } message: {
            Text("YOLO mode allows AI tools to execute commands without approval. This is dangerous and should only be used in controlled environments. Are you sure?")
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { server.isRunning },
                set: { newValue in
                    Task {
                        if newValue {
                            _ = try? await server.start()
                            server.config.isEnabled = true
                        } else {
                            await server.stop()
                            server.config.isEnabled = false
                        }
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Text("Enable MCP Server")
                    SettingPinTag(Settings.AI.mcpServerConfig.erased)
                }
            }
            .themedRow()
            .settingContextMenu(Settings.AI.mcpServerConfig)

            if server.isRunning, let port = server.boundPort {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Running on port \(String(port))")
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            }
        } header: {
            SettingGroupHeader("Server", group: .ai)
        } footer: {
            Text("The MCP server allows AI tools like Claude Code, Codex, and Gemini CLI to execute SSH commands and access cloud resources. New connections require your approval.")
        }
    }

    // MARK: - Security Mode Section

    private var securityModeSection: some View {
        Section {
            Picker(selection: Binding(
                get: { server.config.sessionMode },
                set: { newMode in
                    if newMode == .yolo {
                        showYOLOWarning = true
                        pendingYOLOConfirm = true
                    } else {
                        server.config.sessionMode = newMode
                    }
                }
            )) {
                ForEach(MCPSessionMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.displayName)
                    }
                    .tag(mode)
                }
            } label: {
                Text("Session Mode")
                    .settingRow(Settings.AI.mcpServerConfig)
            }
            .pickerStyle(.menu)
            .themedRow()

            VStack(alignment: .leading, spacing: 4) {
                Text(server.config.sessionMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if server.config.sessionMode == .yolo {
                    Label("All operations auto-approved", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .themedRow()
        } header: {
            SettingGroupHeader("Security", group: .ai)
        } footer: {
            securityModeFooter
        }
    }

    @ViewBuilder
    private var securityModeFooter: some View {
        switch server.config.sessionMode {
        case .standard:
            Text("Safe operations (listing hosts/resources) auto-approve. Dangerous operations (executing commands) require explicit approval.")
        case .cautious:
            Text("All operations require explicit approval. Most secure option.")
        case .yolo:
            Text("All operations auto-approve without asking. Only use this in controlled, trusted environments.")
        }
    }

    // MARK: - Sessions Section

    private var sessionsSection: some View {
        Section {
            if server.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .themedRow()
            } else {
                ForEach(Array(server.sessions.values), id: \.id) { session in
                    MCPSessionRow(session: session) {
                        server.disconnectSession(session.id)
                    }
                    .themedRow()
                }

                if server.sessions.count > 1 {
                    Button("Disconnect All", role: .destructive) {
                        server.disconnectAllSessions()
                    }
                    .themedRow()
                }
            }
        } header: {
            Text("Active Sessions (\(server.sessionCount))")
        }
    }

    // MARK: - CLI Commands Section

    private var cliCommandsSection: some View {
        Section {
            if server.isRunning, let port = server.boundPort {
                VStack(alignment: .leading, spacing: 16) {
                    cliCommand(
                        title: "Claude Code",
                        command: "claude mcp add rootshell -- nc localhost \(port)"
                    )

                    cliCommand(
                        title: "OpenAI Codex",
                        command: "codex mcp add rootshell -- nc localhost \(port)"
                    )

                    cliCommand(
                        title: "Gemini CLI",
                        command: "gemini mcp add rootshell nc localhost \(port)"
                    )
                }
                .themedRow()
            } else {
                Text("Start the server to see CLI commands")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        } header: {
            Text("Add to AI Tools")
        } footer: {
            Text("Run these commands on your Mac to connect AI tools to Rootshell's MCP server.")
        }
    }

    private func cliCommand(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .systemGray6))
                    .cornerRadius(6)

                Button {
                    UIPasteboard.general.string = command
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Session Row

private struct MCPSessionRow: View {
    let session: MCPSession
    let onDisconnect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.body)

                Text("Connected \(session.createdAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onDisconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MCPSettingsView()
    }
}
