//
//  CloudInstancesResource.swift
//  rootshell
//
//  MCP resource provider for cloud VM instances
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// MCP resource provider for cloud VM instances
struct CloudInstancesResourceProvider: MCPResourceProvider {
    static let scheme = "cloud"

    @MainActor
    func listResources() async throws -> [MCPResource] {
        let instances = CloudCacheManager.shared.allInstances

        return instances.map { instance in
            MCPResource(
                uri: "cloud://instances/\(instance.providerID)/\(instance.providerInstanceID)",
                name: instance.label,
                description: "[\(instance.status.displayName)] \(instance.providerID) - \(instance.regionDisplayName)",
                mimeType: "application/json"
            )
        }
    }

    @MainActor
    func readResource(uri: String) async throws -> MCPResourceContent {
        // Parse URI: cloud://instances/{providerID}/{instanceID}
        let path = uri.replacingOccurrences(of: "cloud://instances/", with: "")
        let components = path.split(separator: "/")

        guard components.count >= 2 else {
            throw MCPError.resourceNotFound(uri)
        }

        let providerID = String(components[0])
        let instanceID = String(components[1])

        // Find the instance
        let instances = CloudCacheManager.shared.allInstances
        guard let instance = instances.first(where: {
            $0.providerID == providerID && $0.providerInstanceID == instanceID
        }) else {
            throw MCPError.resourceNotFound(uri)
        }

        // Convert to JSON
        let dto = CloudInstanceDTO(from: instance)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dto)
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"

        return MCPResourceContent(
            uri: uri,
            mimeType: "application/json",
            text: jsonString
        )
    }
}

/// DTO for cloud instance serialization (excludes sensitive data)
private struct CloudInstanceDTO: Codable {
    let id: String
    let label: String
    let provider: String
    let region: String?
    let status: String
    let ipv4: String?
    let ipv6: String?
    let privateIP: String?
    let hostname: String?
    let instanceType: String?
    let image: String?
    let tags: [String]
    let defaultSSHUser: String
    let canSSH: Bool
    let lastUpdated: String

    init(from instance: CloudInstance) {
        self.id = instance.providerInstanceID
        self.label = instance.label
        self.provider = instance.providerID
        self.region = instance.region
        self.status = instance.status.rawValue
        self.ipv4 = instance.ipv4Address
        self.ipv6 = instance.ipv6Address
        self.privateIP = instance.privateIP
        self.hostname = instance.hostname
        self.instanceType = instance.instanceType
        self.image = instance.image
        self.tags = instance.tags
        self.defaultSSHUser = instance.defaultSSHUsername
        self.canSSH = instance.canSSH
        self.lastUpdated = ISO8601DateFormatter().string(from: instance.lastUpdated)
    }
}

