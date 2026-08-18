//
//  MCPSession.swift
//  rootshell
//
//  Represents a connected MCP client session
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import Observation
import os.log

/// Represents a connected MCP client session
@MainActor
@Observable
final class MCPSession: Identifiable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "MCPSession")

    /// Unique session identifier
    let id: UUID

    /// Client connection
    private let connection: MCPClientConnection

    /// Approval manager for this session
    let approvalManager: MCPApprovalManager

    /// Session mode (determines approval behavior)
    let sessionMode: MCPSessionMode

    /// Client info from initialize
    private(set) var clientInfo: MCPClientInfo?

    /// Whether the connection has been approved by the user
    private(set) var isConnectionApproved = false

    /// Whether the session has been initialized
    private(set) var isInitialized = false

    /// Session creation time
    let createdAt: Date

    /// Last activity time
    private(set) var lastActivityAt: Date

    /// Human-readable session name
    var displayName: String {
        if let clientInfo = clientInfo {
            return "\(clientInfo.name) \(clientInfo.version)"
        }
        return "MCP Client \(id.uuidString.prefix(8))"
    }

    /// Reference to request router (set by MCPServer)
    weak var requestRouter: MCPRequestRouter?

    @MainActor
    private var connectionApprovalContinuations: [UUID: AsyncStream<MCPApprovalRequest>.Continuation] = [:]

    /// Stream factory for connection approval requests (forwarded to MCPServer)
    @MainActor
    func connectionApprovalRequestStream() -> AsyncStream<MCPApprovalRequest> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.connectionApprovalContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.connectionApprovalContinuations[id] = nil
                }
            }
        }
    }

    init(
        id: UUID,
        connection: MCPClientConnection,
        sessionMode: MCPSessionMode
    ) {
        self.id = id
        self.connection = connection
        self.sessionMode = sessionMode
        self.createdAt = Date()
        self.lastActivityAt = Date()

        // Create approval manager for this session
        self.approvalManager = MCPApprovalManager(
            sessionID: id,
            sessionName: "MCP Session",
            sessionMode: sessionMode
        )

        // Set up message handling
        connection.setMessageHandler { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleMessage(data)
            }
        }

        Self.logger.info("Session created: \(id.uuidString.prefix(8))")
    }

    deinit {
        let sessionId = id.uuidString.prefix(8)
        Self.logger.info("Session destroyed: \(sessionId)")
    }

    // MARK: - Message Handling

    private func handleMessage(_ data: Data) {
        lastActivityAt = Date()

        do {
            let message = try JSONRPCMessage.parse(from: data)

            switch message {
            case .request(let request):
                Task {
                    let response = await handleRequest(request)
                    sendResponse(response)
                }

            case .notification(let notification):
                handleNotification(notification)

            case .response:
                // We don't expect responses from clients
                Self.logger.warning("Unexpected response from client")
            }
        } catch {
            Self.logger.error("Failed to parse message: \(error.localizedDescription)")
            let response = JSONRPCResponse.error(
                id: nil,
                error: .parseError(error.localizedDescription)
            )
            sendResponse(response)
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        Self.logger.debug("Handling request: \(request.method)")

        // Handle initialize specially (before checking initialization)
        if request.method == "initialize" {
            return await handleInitialize(request)
        }

        // All other requests require initialization
        guard isInitialized else {
            return JSONRPCResponse.error(
                id: request.id,
                error: .sessionNotFound()
            )
        }

        // Route to request router
        guard let router = requestRouter else {
            return JSONRPCResponse.error(
                id: request.id,
                error: .internalError("Request router not configured")
            )
        }

        return await router.handleRequest(request, session: self)
    }

    private func handleNotification(_ notification: JSONRPCNotification) {
        Self.logger.debug("Handling notification: \(notification.method)")

        switch notification.method {
        case MCPNotificationMethod.initialized:
            // Client acknowledges initialization complete
            Self.logger.info("Client acknowledged initialization")

        case MCPNotificationMethod.cancelled:
            // Client cancelled a request
            if let requestId = notification.params?.objectValue?["requestId"]?.stringValue {
                Self.logger.info("Client cancelled request: \(requestId)")
            }

        default:
            Self.logger.debug("Unhandled notification: \(notification.method)")
        }
    }

    // MARK: - Initialize

    private func handleInitialize(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        // Parse initialize params
        guard let params = request.params,
              let paramsDict = params.objectValue else {
            return JSONRPCResponse.error(
                id: request.id,
                error: .invalidParams("Missing initialize params")
            )
        }

        // Parse client info first (needed for approval prompt)
        let clientName: String
        let clientVersion: String
        if let clientInfoDict = paramsDict["clientInfo"]?.objectValue {
            clientName = clientInfoDict["name"]?.stringValue ?? "Unknown Client"
            clientVersion = clientInfoDict["version"]?.stringValue ?? "0.0.0"
            clientInfo = MCPClientInfo(name: clientName, version: clientVersion)
        } else {
            clientName = "Unknown Client"
            clientVersion = "0.0.0"
            clientInfo = MCPClientInfo(name: clientName, version: clientVersion)
        }

        Self.logger.info("Connection request from: \(clientName) v\(clientVersion)")

        // Request connection approval from user
        let approved = await requestConnectionApproval(clientName: clientName, clientVersion: clientVersion)

        if !approved {
            Self.logger.warning("Connection denied by user for: \(clientName)")
            return JSONRPCResponse.error(
                id: request.id,
                error: .authenticationFailed("Connection denied by user")
            )
        }

        // Mark as approved and initialized
        isConnectionApproved = true
        isInitialized = true
        Self.logger.info("Session initialized: \(self.displayName)")

        // Return capabilities
        let result = MCPInitializeResult.standard()
        return JSONRPCResponse.success(
            id: request.id,
            result: result.toMCPAnyCodable()
        )
    }

    /// Request connection approval from the user
    private func requestConnectionApproval(clientName: String, clientVersion: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let request = MCPApprovalRequest(
                sessionID: id,
                clientName: clientName,
                clientVersion: clientVersion
            ) { approved in
                continuation.resume(returning: approved)
            }

            // Publish the request for UI handling
            notifyConnectionApprovalRequest(request)
        }
    }

    @MainActor
    private func notifyConnectionApprovalRequest(_ request: MCPApprovalRequest) {
        for continuation in connectionApprovalContinuations.values {
            continuation.yield(request)
        }
    }

    // MARK: - Response Sending

    private func sendResponse(_ response: JSONRPCResponse) {
        do {
            let data = try JSONRPCMessage.response(response).encode()
            connection.send(data)
        } catch {
            Self.logger.error("Failed to encode response: \(error.localizedDescription)")
        }
    }

    /// Send a notification to the client
    func sendNotification(_ notification: JSONRPCNotification) {
        do {
            let data = try JSONRPCMessage.notification(notification).encode()
            connection.send(data)
        } catch {
            Self.logger.error("Failed to encode notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Session Control

    /// Close the session
    func close() {
        Self.logger.info("Closing session: \(self.id.uuidString.prefix(8))")
        connection.close()
    }

    /// Whether the session is still active
    var isActive: Bool {
        connection.isActive
    }
}
