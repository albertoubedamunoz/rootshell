//
//  MCPApprovalManager.swift
//  rootshell
//
//  Manages approval requests for MCP operations
//  Follows pattern from SSHAgentManager.swift
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import Observation
import os.log
@preconcurrency import UserNotifications
import UIKit

/// Represents a pending MCP approval request
struct MCPApprovalRequest: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sessionName: String
    let tool: String
    let action: String
    let details: [String: String]
    let riskLevel: MCPOperationRisk
    let isConnectionApproval: Bool
    let completion: @Sendable (Bool) -> Void
    let timestamp: Date

    /// Initialize a connection approval request
    init(
        sessionID: UUID,
        clientName: String,
        clientVersion: String,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        self.id = UUID()
        self.sessionID = sessionID
        self.sessionName = "\(clientName) \(clientVersion)"
        self.tool = clientName
        self.action = "Connect (v\(clientVersion))"
        self.details = ["Client": clientName, "Version": clientVersion]
        self.riskLevel = .moderate
        self.isConnectionApproval = true
        self.completion = completion
        self.timestamp = Date()
    }

    /// Initialize a tool execution approval request
    init(
        sessionID: UUID,
        sessionName: String,
        tool: String,
        action: String,
        details: [String: String] = [:],
        riskLevel: MCPOperationRisk,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        self.id = UUID()
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.tool = tool
        self.action = action
        self.details = details
        self.riskLevel = riskLevel
        self.isConnectionApproval = false
        self.completion = completion
        self.timestamp = Date()
    }

    /// Create a unique key for session-level approval caching
    var sessionApprovalKey: String {
        "\(tool):\(action)"
    }
}

/// Manages approval requests for a single MCP session
@MainActor
@Observable
final class MCPApprovalManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "MCPApprovalManager")

    /// Session ID this manager is associated with
    let sessionID: UUID

    /// Session name for display
    let sessionName: String

    /// Current session mode
    let sessionMode: MCPSessionMode

    /// Timeout for approval requests
    let approvalTimeout: TimeInterval

    /// Current pending approval request (not @Published due to Swift KeyPath issues with closure types)
    private(set) var pendingApproval: MCPApprovalRequest?

    /// Operations approved for this session (for sessionApprove mode)
    private var sessionApproved: Set<String> = []

    @MainActor
    private var approvalRequestContinuations: [UUID: AsyncStream<MCPApprovalRequest>.Continuation] = [:]

    /// Stream factory for approval requests (for UI binding)
    @MainActor
    func approvalRequestStream() -> AsyncStream<MCPApprovalRequest> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.approvalRequestContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.approvalRequestContinuations[id] = nil
                }
            }
        }
    }

    /// Reference to notification manager
    private weak var notificationManager: NotificationManager?

    init(
        sessionID: UUID,
        sessionName: String,
        sessionMode: MCPSessionMode = .standard,
        approvalTimeout: TimeInterval = 30,
        notificationManager: NotificationManager? = nil
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.sessionMode = sessionMode
        self.approvalTimeout = approvalTimeout
        self.notificationManager = notificationManager
    }

    // MARK: - Approval Flow

    /// Request approval for an operation
    /// Returns true if approved, false if denied
    func requestApproval(
        tool: String,
        action: String,
        details: [String: String] = [:],
        riskLevel: MCPOperationRisk
    ) async -> Bool {
        // Determine approval mode based on session mode and risk
        let approvalMode = sessionMode.approvalModeFor(risk: riskLevel)

        switch approvalMode {
        case .autoApprove:
            Self.logger.info("Auto-approving \(tool): \(action)")
            return true

        case .sessionApprove:
            let key = "\(tool):\(action)"
            if sessionApproved.contains(key) {
                Self.logger.info("Session-approved \(tool): \(action)")
                return true
            }
            // Fall through to request approval

        case .perRequest:
            break
        }

        // Need to request user approval
        Self.logger.info("Requesting approval for \(tool): \(action)")

        // Calculate session approval key before creating request to avoid circular reference
        let approvalKey = "\(tool):\(action)"

        // Use a class to track if continuation has been resumed (prevent double-resume)
        final class ContinuationState: @unchecked Sendable {
            var resumed = false
        }
        let state = ContinuationState()

        return await withCheckedContinuation { continuation in
            let request = MCPApprovalRequest(
                sessionID: sessionID,
                sessionName: sessionName,
                tool: tool,
                action: action,
                details: details,
                riskLevel: riskLevel,
                completion: { [weak self] approved in
                    // Prevent double-resume
                    guard !state.resumed else { return }
                    state.resumed = true

                    guard let self = self else {
                        continuation.resume(returning: false)
                        return
                    }

                    Task { @MainActor in
                        if approved && self.sessionMode.approvalModeFor(risk: riskLevel) == .sessionApprove {
                            // Cache for session
                            self.sessionApproved.insert(approvalKey)
                        }
                        continuation.resume(returning: approved)
                    }
                }
            )

            pendingApproval = request

            // Check if app is in background
            let isBackground = UIApplication.shared.applicationState == .background

            if isBackground {
                // Schedule notification for background approval
                scheduleApprovalNotification(request)
            }

            // Publish for UI
            notifyApprovalRequest(request)

            // Set timeout
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.approvalTimeout ?? 30))

                await MainActor.run {
                    if self?.pendingApproval?.id == request.id {
                        Self.logger.warning("Approval timeout for \(tool): \(action)")
                        self?.respondToApproval(approved: false, timedOut: true)
                    }
                }
            }
        }
    }

    /// Called by UI when user responds to approval request
    func respondToApproval(approved: Bool, timedOut: Bool = false) {
        guard let request = pendingApproval else {
            Self.logger.warning("No pending approval to respond to")
            return
        }

        Self.logger.info("Approval response for \(request.tool): \(approved ? "approved" : (timedOut ? "timed out" : "denied"))")

        pendingApproval = nil
        request.completion(approved)
    }

    /// Clear all session approvals
    func clearSessionApprovals() {
        sessionApproved.removeAll()
    }

    @MainActor
    private func notifyApprovalRequest(_ request: MCPApprovalRequest) {
        for continuation in approvalRequestContinuations.values {
            continuation.yield(request)
        }
    }

    // MARK: - Background Notifications

    private func scheduleApprovalNotification(_ request: MCPApprovalRequest) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = "MCP Approval Required"
            content.subtitle = "Session: \(request.sessionName)"
            content.body = "\(request.tool): \(request.action)"
            content.sound = .default
            content.categoryIdentifier = "MCP_APPROVAL"
            content.userInfo = [
                "requestId": request.id.uuidString,
                "sessionId": request.sessionID.uuidString,
                "tool": request.tool,
                "action": request.action,
                "riskLevel": request.riskLevel.rawValue
            ]

            let notificationRequest = UNNotificationRequest(
                identifier: "mcp-approval-\(request.id.uuidString)",
                content: content,
                trigger: nil  // Immediate
            )

            do {
                try await UNUserNotificationCenter.current().add(notificationRequest)
                Self.logger.info("Scheduled MCP approval notification")
            } catch {
                Self.logger.error("Failed to schedule MCP approval notification: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notification Category Registration

extension MCPApprovalManager {
    /// Register MCP notification category with actions
    /// Should be called once at app startup
    @MainActor
    static func registerNotificationCategory() {
        let approveAction = UNNotificationAction(
            identifier: "MCP_APPROVE",
            title: "Approve",
            options: [.foreground]
        )

        let denyAction = UNNotificationAction(
            identifier: "MCP_DENY",
            title: "Deny",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: "MCP_APPROVAL",
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Get existing categories and add ours
        Task {
            let existingCategories = await UNUserNotificationCenter.current().notificationCategories()
            var categories = existingCategories
            // Remove existing MCP category if present
            categories = categories.filter { $0.identifier != "MCP_APPROVAL" }
            categories.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }

        logger.info("Registered MCP approval notification category")
    }
}
