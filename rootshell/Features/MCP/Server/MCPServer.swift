//
//  MCPServer.swift
//  rootshell
//
//  Main MCP server coordinator
//  Manages TCP server, sessions, tools, and resources
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import Observation
import os.log

/// Main MCP server coordinator
@MainActor
@Observable
final class MCPServer {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "MCPServer")

    /// Shared singleton instance
    static let shared = MCPServer()

    // MARK: - Published State

    /// Whether the server is running
    private(set) var isRunning = false

    /// Port the server is bound to
    private(set) var boundPort: Int?

    /// Active sessions
    private(set) var sessions: [UUID: MCPSession] = [:]

    /// Number of active sessions
    var sessionCount: Int { sessions.count }

    // MARK: - Configuration

    /// Server configuration
    var config: MCPServerConfig {
        didSet {
            config.save()
        }
    }

    // MARK: - Managers

    /// Request router for handling MCP requests
    let requestRouter: MCPRequestRouter

    /// TCP server for accepting connections
    private var tcpServer: MCPTCPServer?

    @MainActor
    private var approvalRequestContinuations: [UUID: AsyncStream<MCPApprovalRequest>.Continuation] = [:]

    @MainActor
    private var sessionEventContinuations: [UUID: AsyncStream<MCPSessionEvent>.Continuation] = [:]

    // MARK: - Publishers

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

    /// Stream factory for session events
    @MainActor
    func sessionEventStream() -> AsyncStream<MCPSessionEvent> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.sessionEventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sessionEventContinuations[id] = nil
                }
            }
        }
    }

    // MARK: - Initialization

    private init() {
        self.config = MCPServerConfig.load()
        self.requestRouter = MCPRequestRouter()

        // Register built-in tools and resources
        registerBuiltinTools()
        registerBuiltinResourceProviders()

        Self.logger.info("MCPServer initialized")
    }

    // MARK: - Server Lifecycle

    /// Start the MCP server
    @discardableResult
    func start(port: Int? = nil) async throws -> Int {
        guard !isRunning else {
            Self.logger.warning("Server already running")
            return boundPort ?? 0
        }

        // Determine which port to bind
        // Priority: explicit parameter > saved port > auto-assign (0)
        var bindPort = port ?? config.port
        Self.logger.info("Starting MCP server on port \(bindPort)")

        // Create and start TCP server
        let server = MCPTCPServer()
        tcpServer = server

        server.onClientConnected = { [weak self] connection in
            self?.handleClientConnected(connection)
        }

        server.onClientDisconnected = { [weak self] clientID in
            self?.handleClientDisconnected(clientID)
        }

        var actualPort: Int
        do {
            actualPort = try await server.start(port: bindPort)
        } catch {
            // If we failed to bind and we were using a saved port, try auto-assign
            if bindPort != 0 {
                Self.logger.warning("Failed to bind to saved port \(bindPort), trying auto-assign")
                bindPort = 0
                actualPort = try await server.start(port: 0)
            } else {
                throw error
            }
        }

        boundPort = actualPort
        isRunning = true

        // Persist the port so we reuse it on next start
        // This only updates if the port changed (auto-assigned or conflict recovery)
        if config.port != actualPort {
            config.port = actualPort
            Self.logger.info("Saved port \(actualPort) for future restarts")
        }

        Self.logger.info("MCP server started on port \(actualPort)")
        return actualPort
    }

    /// Stop the MCP server
    func stop() async {
        guard isRunning else { return }

        Self.logger.info("Stopping MCP server")

        // Close all sessions
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()

        // Stop TCP server
        await tcpServer?.stop()
        tcpServer = nil

        boundPort = nil
        isRunning = false

        Self.logger.info("MCP server stopped")
    }

    /// Restart the server (stop then start)
    func restart() async throws {
        let port = boundPort ?? config.port
        await stop()
        try await start(port: port)
    }

    // MARK: - Client Handling

    private func handleClientConnected(_ connection: MCPClientConnection) {
        let sessionID = connection.id

        Self.logger.info("New client connection: \(sessionID.uuidString.prefix(8))")

        // Create session
        let session = MCPSession(
            id: sessionID,
            connection: connection,
            sessionMode: config.sessionMode
        )

        // Set up request router
        session.requestRouter = requestRouter

        // Forward connection approval requests to our publisher
        Task {
            for await request in session.connectionApprovalRequestStream() {
                notifyApprovalRequest(request)
            }
        }

        // Forward tool approval requests to our publisher
        Task {
            for await request in session.approvalManager.approvalRequestStream() {
                notifyApprovalRequest(request)
            }
        }

        // Store session
        sessions[sessionID] = session

        // Publish event
        notifySessionEvent(.connected(session))
    }

    private func handleClientDisconnected(_ clientID: UUID) {
        Self.logger.info("Client disconnected: \(clientID.uuidString.prefix(8))")

        if let session = sessions.removeValue(forKey: clientID) {
            notifySessionEvent(.disconnected(session))
        }
    }

    @MainActor
    private func notifyApprovalRequest(_ request: MCPApprovalRequest) {
        for continuation in approvalRequestContinuations.values {
            continuation.yield(request)
        }
    }

    @MainActor
    private func notifySessionEvent(_ event: MCPSessionEvent) {
        for continuation in sessionEventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Session Management

    /// Get a session by ID
    func session(for id: UUID) -> MCPSession? {
        sessions[id]
    }

    /// Disconnect a session
    func disconnectSession(_ id: UUID) {
        if let session = sessions[id] {
            session.close()
            sessions.removeValue(forKey: id)
            notifySessionEvent(.disconnected(session))
        }
    }

    /// Disconnect all sessions
    func disconnectAllSessions() {
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
    }

    // MARK: - Tool Registration

    /// Register a tool
    func registerTool(_ tool: any MCPTool) {
        requestRouter.registerTool(tool)
    }

    /// Register a resource provider
    func registerResourceProvider(_ provider: any MCPResourceProvider) {
        requestRouter.registerResourceProvider(provider)
    }

    // MARK: - Built-in Registration

    private func registerBuiltinTools() {
        // SSH tools
        registerTool(SSHExecuteTool())
        registerTool(SSHListHostsTool())
        registerTool(SSHGetHostInfoTool())

        // Cloud tools
        registerTool(CloudListInstancesTool())

        Self.logger.debug("Built-in tools registered")
    }

    private func registerBuiltinResourceProviders() {
        // Cloud and Kubernetes resource providers
        registerResourceProvider(CloudInstancesResourceProvider())
        registerResourceProvider(KubernetesClustersResourceProvider())
        Self.logger.debug("Built-in resource providers registered")
    }

    // MARK: - Approval Handling

    /// Respond to an approval request
    func respondToApproval(sessionID: UUID, approved: Bool) {
        if let session = sessions[sessionID] {
            session.approvalManager.respondToApproval(approved: approved)
        }
    }
}

// MARK: - Session Events

/// Events for session lifecycle
enum MCPSessionEvent {
    case connected(MCPSession)
    case disconnected(MCPSession)
}

// MARK: - Convenience Extensions

extension MCPServer {
    /// Whether there are any active sessions
    var hasActiveSessions: Bool {
        !sessions.isEmpty
    }
}
