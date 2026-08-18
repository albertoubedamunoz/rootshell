//
//  MCPApprovalView.swift
//  rootshell
//
//  Overlay view for handling MCP approval requests
//  Self-contained to avoid type-checking complexity in MainView
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import SwiftUI
import os.log

/// Overlay view that handles MCP approval requests
/// Add this as an overlay on the root view of your app
struct MCPApprovalOverlay: View {
    private static let logger = Logger(subsystem: "com.rootshell", category: "MCPApprovalOverlay")

    @State private var approvalQueue: [MCPApprovalRequest] = []
    @State private var showAlert = false
    @State private var approvalTask: Task<Void, Never>? = nil
    @State private var notificationObserver: NSObjectProtocol? = nil

    var body: some View {
        Color.clear
            .alert(alertTitle, isPresented: $showAlert) {
                Button("Deny", role: .cancel) {
                    respondToApproval(approved: false)
                }
                Button(approveButtonTitle) {
                    respondToApproval(approved: true)
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                if let request = approvalQueue.first {
                    Text(approvalMessage(for: request))
                }
            }
            .onAppear {
                setupObservers()
            }
            .onDisappear {
                approvalTask?.cancel()
                approvalTask = nil
                if let observer = notificationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    notificationObserver = nil
                }
            }
    }

    private var alertTitle: String {
        guard let request = approvalQueue.first else { return "MCP Approval" }
        if request.isConnectionApproval {
            return "New MCP Connection"
        }
        return "MCP Tool Request"
    }

    private var approveButtonTitle: String {
        guard let request = approvalQueue.first else { return "Approve" }
        if request.isConnectionApproval {
            return "Allow"
        }
        return "Approve"
    }

    private func setupObservers() {
        // Handle MCP approval responses from background notifications
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .mcpApprovalResponse,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let sessionId = userInfo["sessionId"] as? UUID,
                  let approved = userInfo["approved"] as? Bool else { return }

            // Forward the response to the MCP server
            Task { @MainActor in
                MCPServer.shared.respondToApproval(sessionID: sessionId, approved: approved)
            }
        }

        approvalTask?.cancel()
        approvalTask = Task { @MainActor in
            for await request in MCPServer.shared.approvalRequestStream() {
                handleApprovalRequest(request)
            }
        }
    }

    private func handleApprovalRequest(_ request: MCPApprovalRequest) {
        Self.logger.info("MCP approval request received for tool: \(request.tool)")
        approvalQueue.append(request)
        if !showAlert {
            showAlert = true
        }
    }

    private func respondToApproval(approved: Bool) {
        // Complete the current request (first in queue)
        if let currentRequest = approvalQueue.first {
            currentRequest.completion(approved)
            approvalQueue.removeFirst()
        }

        // SwiftUI's alert automatically dismisses when button is pressed.
        // If there are more requests, we need to re-show the alert on next runloop.
        if !approvalQueue.isEmpty {
            // Delay slightly to allow SwiftUI's dismiss animation to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                showAlert = true
            }
        }
    }

    private func approvalMessage(for request: MCPApprovalRequest) -> String {
        if request.isConnectionApproval {
            return "\"\(request.tool)\" wants to connect to your MCP server.\n\nThis will allow the AI tool to execute SSH commands and access cloud resources based on your security settings."
        } else {
            var message = "Session: \(request.sessionName)\n\nTool: \(request.tool)\nAction: \(request.action)"
            if !request.details.isEmpty {
                let detailLines = request.details.map { "\($0.key): \($0.value)" }
                message += "\n\n" + detailLines.joined(separator: "\n")
            }
            return message
        }
    }
}

#Preview {
    MCPApprovalOverlay()
}
