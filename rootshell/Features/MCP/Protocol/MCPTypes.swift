//
//  MCPTypes.swift
//  rootshell
//
//  MCP protocol types for capability negotiation and tool/resource definitions
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

// MARK: - Protocol Version

/// MCP protocol version
enum MCPProtocol {
    static let version = "2025-06-18"
}

// MARK: - Server Info

/// Information about the MCP server
struct MCPServerInfo: Codable, Sendable {
    let name: String
    let version: String

    static let current = MCPServerInfo(
        name: "rootshell",
        version: "1.0.0"
    )
}

// MARK: - Client Info

/// Information about the MCP client
struct MCPClientInfo: Codable, Sendable {
    let name: String
    let version: String
}

// MARK: - Server Capabilities

/// Capabilities the MCP server supports
struct MCPServerCapabilities: Codable, Sendable {
    let tools: ToolsCapability?
    let resources: ResourcesCapability?
    let prompts: PromptsCapability?
    let logging: LoggingCapability?

    struct ToolsCapability: Codable, Sendable {
        let listChanged: Bool?

        static let standard = ToolsCapability(listChanged: false)
    }

    struct ResourcesCapability: Codable, Sendable {
        let subscribe: Bool?
        let listChanged: Bool?

        static let standard = ResourcesCapability(subscribe: false, listChanged: true)
    }

    struct PromptsCapability: Codable, Sendable {
        let listChanged: Bool?

        static let none: PromptsCapability? = nil
    }

    struct LoggingCapability: Codable, Sendable {
        // Empty for now - presence indicates support
    }

    /// Standard capabilities for rootshell MCP server
    static let standard = MCPServerCapabilities(
        tools: .standard,
        resources: .standard,
        prompts: nil,
        logging: LoggingCapability()
    )
}

// MARK: - Client Capabilities

/// Capabilities the MCP client supports
struct MCPClientCapabilities: Codable, Sendable {
    let roots: RootsCapability?
    let sampling: SamplingCapability?

    struct RootsCapability: Codable, Sendable {
        let listChanged: Bool?
    }

    struct SamplingCapability: Codable, Sendable {
        // Empty - presence indicates support
    }
}

// MARK: - Initialize Request/Response

/// Parameters for the initialize request
struct MCPInitializeParams: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPClientCapabilities?
    let clientInfo: MCPClientInfo?
    /// Authentication token (rootshell extension)
    let token: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case capabilities
        case clientInfo
        case token
    }
}

/// Result of the initialize request
struct MCPInitializeResult: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo

    /// Create standard initialize result
    static func standard() -> MCPInitializeResult {
        MCPInitializeResult(
            protocolVersion: MCPProtocol.version,
            capabilities: .standard,
            serverInfo: .current
        )
    }

    /// Convert to MCPAnyCodable for JSON-RPC response
    func toMCPAnyCodable() -> MCPAnyCodable {
        MCPAnyCodable([
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": capabilities.tools.map { ["listChanged": $0.listChanged ?? false] } as Any,
                "resources": capabilities.resources.map { [
                    "subscribe": $0.subscribe ?? false,
                    "listChanged": $0.listChanged ?? false
                ] } as Any,
                "logging": capabilities.logging != nil ? [:] : nil
            ].compactMapValues { $0 },
            "serverInfo": [
                "name": serverInfo.name,
                "version": serverInfo.version
            ]
        ])
    }
}

// MARK: - Tool Definition

/// MCP Tool definition
struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: MCPInputSchema

    func toMCPAnyCodable() -> MCPAnyCodable {
        MCPAnyCodable([
            "name": name,
            "description": description,
            "inputSchema": inputSchema.toDict()
        ])
    }
}

/// JSON Schema for tool input
struct MCPInputSchema: Codable, Sendable {
    let type: String
    let properties: [String: MCPPropertySchema]
    let required: [String]?

    init(properties: [String: MCPPropertySchema], required: [String]? = nil) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "type": type,
            "properties": properties.mapValues { $0.toDict() }
        ]
        if let required = required {
            dict["required"] = required
        }
        return dict
    }
}

/// JSON Schema property definition
struct MCPPropertySchema: Codable, Sendable {
    let type: String
    let description: String?
    let enumValues: [String]?

    init(type: String, description: String? = nil, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
    }

    static func string(description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "string", description: description)
    }

    static func integer(description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "integer", description: description)
    }

    static func boolean(description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "boolean", description: description)
    }

    static func stringEnum(_ values: [String], description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "string", description: description, enumValues: values)
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if let description = description {
            dict["description"] = description
        }
        if let enumValues = enumValues {
            dict["enum"] = enumValues
        }
        return dict
    }
}

// MARK: - Tool Call

/// Parameters for tools/call request
struct MCPToolCallParams: Sendable {
    let name: String
    let arguments: [String: MCPAnyCodable]

    init?(from params: MCPAnyCodable?) {
        guard let dict = params?.objectValue,
              let name = dict["name"]?.stringValue else {
            return nil
        }
        self.name = name
        self.arguments = dict["arguments"]?.objectValue ?? [:]
    }

    func stringArg(_ key: String) -> String? {
        arguments[key]?.stringValue
    }

    func intArg(_ key: String) -> Int? {
        arguments[key]?.intValue
    }

    func boolArg(_ key: String) -> Bool? {
        arguments[key]?.boolValue
    }
}

/// Result of a tool call
struct MCPToolResult: Sendable {
    let content: [MCPContent]
    let isError: Bool

    init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// Create a text result
    static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)])
    }

    /// Create a JSON result
    static func json(_ value: Any) -> MCPToolResult {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return MCPToolResult(content: [.text(string)])
        }
        return MCPToolResult(content: [.text("{}")])
    }

    /// Create an error result
    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text("Error: \(message)")], isError: true)
    }

    func toMCPAnyCodable() -> MCPAnyCodable {
        MCPAnyCodable([
            "content": content.map { $0.toDict() },
            "isError": isError
        ])
    }
}

/// Content types for tool results
enum MCPContent: Sendable {
    case text(String)
    case image(data: String, mimeType: String)  // base64 encoded

    func toDict() -> [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let data, let mimeType):
            return ["type": "image", "data": data, "mimeType": mimeType]
        }
    }
}

// MARK: - Resource Definition

/// MCP Resource definition
struct MCPResource: Codable, Sendable {
    let uri: String
    let name: String
    let description: String?
    let mimeType: String

    func toMCPAnyCodable() -> MCPAnyCodable {
        var dict: [String: Any] = [
            "uri": uri,
            "name": name,
            "mimeType": mimeType
        ]
        if let description = description {
            dict["description"] = description
        }
        return MCPAnyCodable(dict)
    }
}

/// MCP Resource content (result of resources/read)
struct MCPResourceContent: Sendable {
    let uri: String
    let mimeType: String
    let text: String?
    let blob: String?  // base64 encoded binary data

    init(uri: String, mimeType: String, text: String) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = nil
    }

    init(uri: String, mimeType: String, blob: String) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = nil
        self.blob = blob
    }

    func toMCPAnyCodable() -> MCPAnyCodable {
        var dict: [String: Any] = [
            "uri": uri,
            "mimeType": mimeType
        ]
        if let text = text {
            dict["text"] = text
        }
        if let blob = blob {
            dict["blob"] = blob
        }
        return MCPAnyCodable(dict)
    }
}

// MARK: - Resources List/Read

/// Parameters for resources/read request
struct MCPResourceReadParams: Sendable {
    let uri: String

    init?(from params: MCPAnyCodable?) {
        guard let uri = params?.objectValue?["uri"]?.stringValue else {
            return nil
        }
        self.uri = uri
    }
}

// MARK: - Notifications

/// Standard MCP notification methods
enum MCPNotificationMethod {
    static let initialized = "notifications/initialized"
    static let cancelled = "notifications/cancelled"
    static let progress = "notifications/progress"
    static let resourcesListChanged = "notifications/resources/list_changed"
    static let toolsListChanged = "notifications/tools/list_changed"
}
