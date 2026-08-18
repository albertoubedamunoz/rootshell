//
//  JSONRPCMessage.swift
//  rootshell
//
//  JSON-RPC 2.0 message types for MCP protocol
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

// MARK: - JSON-RPC Version

/// JSON-RPC protocol version
enum JSONRPCVersion {
    static let version = "2.0"
}

// MARK: - Request ID

/// JSON-RPC request ID - can be string, integer, or null
enum RequestID: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Request ID must be string, integer, or null"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringRepresentation: String {
        switch self {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .null: return "null"
        }
    }
}

// MARK: - JSON-RPC Request

/// JSON-RPC 2.0 request message
struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: RequestID
    let method: String
    let params: MCPAnyCodable?

    init(id: RequestID, method: String, params: MCPAnyCodable? = nil) {
        self.jsonrpc = JSONRPCVersion.version
        self.id = id
        self.method = method
        self.params = params
    }

    /// Get params as a dictionary
    var paramsDict: [String: MCPAnyCodable]? {
        params?.objectValue
    }

    /// Get a string parameter
    func stringParam(_ key: String) -> String? {
        paramsDict?[key]?.stringValue
    }

    /// Get an integer parameter
    func intParam(_ key: String) -> Int? {
        paramsDict?[key]?.intValue
    }

    /// Get a boolean parameter
    func boolParam(_ key: String) -> Bool? {
        paramsDict?[key]?.boolValue
    }
}

// MARK: - JSON-RPC Response

/// JSON-RPC 2.0 response message
struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: RequestID
    let result: MCPAnyCodable?
    let error: JSONRPCError?

    /// Create a successful response
    static func success(id: RequestID, result: MCPAnyCodable) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: JSONRPCVersion.version,
            id: id,
            result: result,
            error: nil
        )
    }

    /// Create an error response
    static func error(id: RequestID, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: JSONRPCVersion.version,
            id: id,
            result: nil,
            error: error
        )
    }

    /// Create an error response from RequestID (may be null for parse errors)
    static func error(id: RequestID?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: JSONRPCVersion.version,
            id: id ?? .null,
            result: nil,
            error: error
        )
    }
}

// MARK: - JSON-RPC Error

/// JSON-RPC 2.0 error object
struct JSONRPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: MCPAnyCodable?

    init(code: Int, message: String, data: MCPAnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC error codes
    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let methodNotFoundCode = -32601
    static let invalidParamsCode = -32602
    static let internalErrorCode = -32603

    // MCP-specific error codes (-32000 to -32099 are reserved for implementation)
    static let authenticationRequiredCode = -32001
    static let authenticationFailedCode = -32002
    static let approvalDeniedCode = -32003
    static let approvalTimeoutCode = -32004
    static let sessionNotFoundCode = -32005
    static let resourceNotFoundCode = -32006
    static let toolExecutionFailedCode = -32007

    // Standard errors
    static func parseError(_ details: String? = nil) -> JSONRPCError {
        JSONRPCError(
            code: parseErrorCode,
            message: "Parse error",
            data: details.map { MCPAnyCodable($0) }
        )
    }

    static func invalidRequest(_ details: String? = nil) -> JSONRPCError {
        JSONRPCError(
            code: invalidRequestCode,
            message: "Invalid Request",
            data: details.map { MCPAnyCodable($0) }
        )
    }

    static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(
            code: methodNotFoundCode,
            message: "Method not found: \(method)",
            data: nil
        )
    }

    static func invalidParams(_ details: String) -> JSONRPCError {
        JSONRPCError(
            code: invalidParamsCode,
            message: "Invalid params: \(details)",
            data: nil
        )
    }

    static func internalError(_ details: String? = nil) -> JSONRPCError {
        JSONRPCError(
            code: internalErrorCode,
            message: details ?? "Internal error",
            data: nil
        )
    }

    // MCP-specific errors
    static func authenticationRequired() -> JSONRPCError {
        JSONRPCError(
            code: authenticationRequiredCode,
            message: "Authentication required",
            data: nil
        )
    }

    static func authenticationFailed(_ details: String? = nil) -> JSONRPCError {
        JSONRPCError(
            code: authenticationFailedCode,
            message: details ?? "Authentication failed",
            data: nil
        )
    }

    static func approvalDenied(_ operation: String) -> JSONRPCError {
        JSONRPCError(
            code: approvalDeniedCode,
            message: "User denied approval for: \(operation)",
            data: nil
        )
    }

    static func approvalTimeout(_ operation: String) -> JSONRPCError {
        JSONRPCError(
            code: approvalTimeoutCode,
            message: "Approval timed out for: \(operation)",
            data: nil
        )
    }

    static func sessionNotFound() -> JSONRPCError {
        JSONRPCError(
            code: sessionNotFoundCode,
            message: "Session not found or not initialized",
            data: nil
        )
    }

    static func resourceNotFound(_ uri: String) -> JSONRPCError {
        JSONRPCError(
            code: resourceNotFoundCode,
            message: "Resource not found: \(uri)",
            data: nil
        )
    }

    static func toolExecutionFailed(_ details: String) -> JSONRPCError {
        JSONRPCError(
            code: toolExecutionFailedCode,
            message: "Tool execution failed: \(details)",
            data: nil
        )
    }
}

// MARK: - JSON-RPC Notification

/// JSON-RPC 2.0 notification (no id, no response expected)
struct JSONRPCNotification: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: MCPAnyCodable?

    init(method: String, params: MCPAnyCodable? = nil) {
        self.jsonrpc = JSONRPCVersion.version
        self.method = method
        self.params = params
    }
}

// MARK: - Message Parsing

/// Represents any JSON-RPC message (request, response, or notification)
enum JSONRPCMessage: Sendable {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)

    /// Parse a JSON-RPC message from data
    static func parse(from data: Data) throws -> JSONRPCMessage {
        let decoder = JSONDecoder()

        // Try to decode as a generic structure first to determine type
        struct MessageProbe: Decodable {
            let id: RequestID?
            let method: String?
            let result: MCPAnyCodable?
            let error: JSONRPCError?

            enum CodingKeys: String, CodingKey {
                case id, method, result, error
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.id = try container.decodeIfPresent(RequestID.self, forKey: .id)
                self.method = try container.decodeIfPresent(String.self, forKey: .method)
                self.result = try container.decodeIfPresent(MCPAnyCodable.self, forKey: .result)
                self.error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
            }
        }

        let probe = try decoder.decode(MessageProbe.self, from: data)

        // Determine message type based on presence of fields
        if probe.result != nil || probe.error != nil {
            // It's a response
            let response = try decoder.decode(JSONRPCResponse.self, from: data)
            return .response(response)
        } else if probe.method != nil {
            if probe.id != nil {
                // It's a request (has id and method)
                let request = try decoder.decode(JSONRPCRequest.self, from: data)
                return .request(request)
            } else {
                // It's a notification (has method but no id)
                let notification = try decoder.decode(JSONRPCNotification.self, from: data)
                return .notification(notification)
            }
        } else {
            throw JSONRPCParseError.invalidMessage
        }
    }

    /// Encode the message to data
    func encode() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .request(let request):
            return try encoder.encode(request)
        case .response(let response):
            return try encoder.encode(response)
        case .notification(let notification):
            return try encoder.encode(notification)
        }
    }
}

/// Errors that can occur during JSON-RPC parsing
enum JSONRPCParseError: Error {
    case invalidMessage
    case invalidJSON
}
