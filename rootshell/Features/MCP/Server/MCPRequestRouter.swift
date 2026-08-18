//
//  MCPRequestRouter.swift
//  rootshell
//
//  Routes MCP requests to appropriate handlers
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import os.log

/// Protocol for MCP tools
protocol MCPTool: Sendable {
    /// Tool name (used in tools/call)
    static var name: String { get }

    /// Human-readable description
    static var description: String { get }

    /// JSON Schema for input parameters
    static var inputSchema: MCPInputSchema { get }

    /// Risk level for this tool
    static var operationRisk: MCPOperationRisk { get }

    /// Execute the tool
    @MainActor
    func execute(params: MCPToolCallParams, session: MCPSession) async throws -> MCPToolResult
}

/// Protocol for MCP resource providers
protocol MCPResourceProvider: Sendable {
    /// URI scheme for this resource type (e.g., "cloud", "k8s")
    static var scheme: String { get }

    /// List available resources
    @MainActor
    func listResources() async throws -> [MCPResource]

    /// Read a specific resource by URI
    @MainActor
    func readResource(uri: String) async throws -> MCPResourceContent
}

/// Routes MCP requests to appropriate handlers
@MainActor
final class MCPRequestRouter {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "MCPRequestRouter")

    /// Registered tools (name -> tool instance)
    private var tools: [String: any MCPTool] = [:]

    /// Registered resource providers (scheme -> provider)
    private var resourceProviders: [String: any MCPResourceProvider] = [:]

    init() {
        // Tools and resource providers are registered by MCPServer
    }

    // MARK: - Registration

    /// Register a tool
    func registerTool(_ tool: any MCPTool) {
        let name = type(of: tool).name
        tools[name] = tool
        Self.logger.debug("Registered tool: \(name)")
    }

    /// Register a resource provider
    func registerResourceProvider(_ provider: any MCPResourceProvider) {
        let scheme = type(of: provider).scheme
        resourceProviders[scheme] = provider
        Self.logger.debug("Registered resource provider: \(scheme)")
    }

    // MARK: - Request Handling

    /// Handle an MCP request
    func handleRequest(_ request: JSONRPCRequest, session: MCPSession) async -> JSONRPCResponse {
        do {
            let result = try await routeRequest(request, session: session)
            return JSONRPCResponse.success(id: request.id, result: result)
        } catch let error as MCPError {
            return JSONRPCResponse.error(id: request.id, error: error.toJSONRPCError())
        } catch {
            return JSONRPCResponse.error(
                id: request.id,
                error: .internalError(error.localizedDescription)
            )
        }
    }

    private func routeRequest(_ request: JSONRPCRequest, session: MCPSession) async throws -> MCPAnyCodable {
        switch request.method {
        case "tools/list":
            return try await handleToolsList()

        case "tools/call":
            return try await handleToolsCall(request, session: session)

        case "resources/list":
            return try await handleResourcesList()

        case "resources/read":
            return try await handleResourcesRead(request)

        default:
            throw MCPError.methodNotFound(request.method)
        }
    }

    // MARK: - Tools

    private func handleToolsList() async throws -> MCPAnyCodable {
        let toolDefs = tools.values.map { tool -> MCPToolDefinition in
            let toolType = type(of: tool)
            return MCPToolDefinition(
                name: toolType.name,
                description: toolType.description,
                inputSchema: toolType.inputSchema
            )
        }

        return MCPAnyCodable([
            "tools": toolDefs.map { $0.toMCPAnyCodable() }
        ])
    }

    private func handleToolsCall(_ request: JSONRPCRequest, session: MCPSession) async throws -> MCPAnyCodable {
        guard let params = MCPToolCallParams(from: request.params) else {
            throw MCPError.invalidParams("Missing tool name or arguments")
        }

        guard let tool = tools[params.name] else {
            throw MCPError.toolNotFound(params.name)
        }

        let toolType = type(of: tool)
        let riskLevel = toolType.operationRisk

        // Request approval if needed
        let approved = await session.approvalManager.requestApproval(
            tool: params.name,
            action: describeToolAction(params),
            details: params.arguments.compactMapValues { $0.stringValue },
            riskLevel: riskLevel
        )

        guard approved else {
            throw MCPError.approvalDenied(params.name)
        }

        // Execute the tool
        Self.logger.info("Executing tool: \(params.name)")
        let result = try await tool.execute(params: params, session: session)
        return result.toMCPAnyCodable()
    }

    /// Create a human-readable description of a tool action
    private func describeToolAction(_ params: MCPToolCallParams) -> String {
        switch params.name {
        case "ssh_execute":
            let host = params.stringArg("host") ?? "unknown"
            let command = params.stringArg("command") ?? "unknown"
            let truncatedCmd = command.count > 50 ? String(command.prefix(50)) + "..." : command
            return "Execute on \(host): \(truncatedCmd)"

        case "ssh_list_hosts":
            return "List SSH hosts"

        case "ssh_get_host_info":
            let host = params.stringArg("host") ?? "unknown"
            return "Get info for \(host)"

        default:
            return "Execute \(params.name)"
        }
    }

    // MARK: - Resources

    private func handleResourcesList() async throws -> MCPAnyCodable {
        var allResources: [MCPResource] = []

        for provider in resourceProviders.values {
            let resources = try await provider.listResources()
            allResources.append(contentsOf: resources)
        }

        return MCPAnyCodable([
            "resources": allResources.map { $0.toMCPAnyCodable() }
        ])
    }

    private func handleResourcesRead(_ request: JSONRPCRequest) async throws -> MCPAnyCodable {
        guard let params = MCPResourceReadParams(from: request.params) else {
            throw MCPError.invalidParams("Missing resource URI")
        }

        // Parse URI scheme
        guard let schemeEnd = params.uri.firstIndex(of: ":"),
              params.uri.index(after: schemeEnd) < params.uri.endIndex,
              params.uri[params.uri.index(after: schemeEnd)...].hasPrefix("//") else {
            throw MCPError.invalidParams("Invalid resource URI format: \(params.uri)")
        }

        let scheme = String(params.uri[..<schemeEnd])

        guard let provider = resourceProviders[scheme] else {
            throw MCPError.resourceNotFound("No provider for scheme: \(scheme)")
        }

        let content = try await provider.readResource(uri: params.uri)

        return MCPAnyCodable([
            "contents": [content.toMCPAnyCodable()]
        ])
    }
}
