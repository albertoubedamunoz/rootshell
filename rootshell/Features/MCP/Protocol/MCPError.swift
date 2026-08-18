//
//  MCPError.swift
//  rootshell
//
//  Error types for MCP operations
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Errors that can occur during MCP operations
enum MCPError: LocalizedError, Sendable {
    // Protocol errors
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)

    // Authentication errors
    case authenticationRequired
    case authenticationFailed(String)

    // Approval errors
    case approvalDenied(String)
    case approvalTimeout(String)

    // Session errors
    case sessionNotFound
    case sessionNotInitialized

    // Resource errors
    case resourceNotFound(String)
    case resourceReadFailed(String)

    // Tool errors
    case toolNotFound(String)
    case toolExecutionFailed(String)

    // SSH-specific errors
    case sshConnectionFailed(String)
    case sshCommandFailed(String)
    case sshHostNotFound(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let details):
            return "Parse error: \(details)"
        case .invalidRequest(let details):
            return "Invalid request: \(details)"
        case .methodNotFound(let method):
            return "Method not found: \(method)"
        case .invalidParams(let details):
            return "Invalid parameters: \(details)"
        case .internalError(let details):
            return "Internal error: \(details)"
        case .authenticationRequired:
            return "Authentication required"
        case .authenticationFailed(let details):
            return "Authentication failed: \(details)"
        case .approvalDenied(let operation):
            return "User denied approval for: \(operation)"
        case .approvalTimeout(let operation):
            return "Approval timed out for: \(operation)"
        case .sessionNotFound:
            return "Session not found"
        case .sessionNotInitialized:
            return "Session not initialized - call initialize first"
        case .resourceNotFound(let uri):
            return "Resource not found: \(uri)"
        case .resourceReadFailed(let details):
            return "Failed to read resource: \(details)"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .toolExecutionFailed(let details):
            return "Tool execution failed: \(details)"
        case .sshConnectionFailed(let details):
            return "SSH connection failed: \(details)"
        case .sshCommandFailed(let details):
            return "SSH command failed: \(details)"
        case .sshHostNotFound(let host):
            return "SSH host not found: \(host)"
        }
    }

    /// Convert to JSON-RPC error
    func toJSONRPCError() -> JSONRPCError {
        switch self {
        case .parseError(let details):
            return .parseError(details)
        case .invalidRequest(let details):
            return .invalidRequest(details)
        case .methodNotFound(let method):
            return .methodNotFound(method)
        case .invalidParams(let details):
            return .invalidParams(details)
        case .internalError(let details):
            return .internalError(details)
        case .authenticationRequired:
            return .authenticationRequired()
        case .authenticationFailed(let details):
            return .authenticationFailed(details)
        case .approvalDenied(let operation):
            return .approvalDenied(operation)
        case .approvalTimeout(let operation):
            return .approvalTimeout(operation)
        case .sessionNotFound, .sessionNotInitialized:
            return .sessionNotFound()
        case .resourceNotFound(let uri):
            return .resourceNotFound(uri)
        case .resourceReadFailed(let details):
            return .internalError("Resource read failed: \(details)")
        case .toolNotFound(let name):
            return .methodNotFound("Tool: \(name)")
        case .toolExecutionFailed(let details):
            return .toolExecutionFailed(details)
        case .sshConnectionFailed(let details):
            return .toolExecutionFailed("SSH connection: \(details)")
        case .sshCommandFailed(let details):
            return .toolExecutionFailed("SSH command: \(details)")
        case .sshHostNotFound(let host):
            return .toolExecutionFailed("SSH host not found: \(host)")
        }
    }
}
