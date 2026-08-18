//
//  MCPStatusView.swift
//  rootshell
//
//  Status indicator for MCP server
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Compact status indicator for MCP server
/// Can be used in sidebar or toolbar
struct MCPStatusIndicator: View {
    @State private var server = MCPServer.shared

    var body: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Label
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Session count badge
            if server.sessionCount > 0 {
                Text("\(server.sessionCount)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    private var statusColor: Color {
        if server.isRunning {
            return server.sessionCount > 0 ? .green : .orange
        }
        return .gray
    }

    private var statusText: String {
        if server.isRunning {
            if let port = server.boundPort {
                return "MCP :\(String(port))"
            }
            return "MCP"
        }
        return "MCP Off"
    }
}

/// Larger status view with more details
struct MCPStatusDetailView: View {
    @State private var server = MCPServer.shared
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("MCP Server", systemImage: "server.rack")
                    .font(.headline)

                Spacer()

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }

            Divider()

            // Status
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(server.isRunning ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(server.isRunning ? String(localized: "Running", comment: "MCP server status: running") : String(localized: "Stopped", comment: "MCP server status: stopped"))
                        .foregroundStyle(.secondary)
                }
            }

            // Port
            if server.isRunning, let port = server.boundPort {
                HStack {
                    Text("Port")
                    Spacer()
                    Text(String(port))
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            // Sessions
            HStack {
                Text("Sessions")
                Spacer()
                Text("\(server.sessionCount)")
                    .foregroundStyle(.secondary)
            }

            // Security Mode
            HStack {
                Text("Mode")
                Spacer()
                Text(server.config.sessionMode.displayName)
                    .foregroundStyle(server.config.sessionMode == .yolo ? .orange : .secondary)
            }

            Divider()

            // Quick actions
            HStack {
                if server.isRunning {
                    Button("Stop") {
                        Task {
                            await server.stop()
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start") {
                        Task {
                            try? await server.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()

                Button("Settings") {
                    showSettings = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                MCPSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
    }
}

/// Toolbar button for MCP status
struct MCPToolbarButton: View {
    @State private var server = MCPServer.shared
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "server.rack")

                if server.isRunning {
                    Circle()
                        .fill(server.sessionCount > 0 ? .green : .orange)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .popover(isPresented: $showPopover) {
            MCPStatusDetailView()
                .frame(width: 280)
        }
    }
}

// MARK: - Previews

#Preview("Indicator") {
    MCPStatusIndicator()
        .padding()
}

#Preview("Detail View") {
    MCPStatusDetailView()
        .padding()
}
