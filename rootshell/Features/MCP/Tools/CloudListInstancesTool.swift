//
//  CloudListInstancesTool.swift
//  rootshell
//
//  MCP tool for listing cloud VM instances
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Tool for listing cloud VM instances from configured cloud accounts
struct CloudListInstancesTool: MCPTool {
    static let name = "cloud_list_instances"
    static let description = """
        List cloud VM instances from configured cloud accounts (AWS, Azure, Linode, DigitalOcean). \
        Use this tool to find VMs by name, then use the returned IP address with ssh_execute. \
        Returns instance name, status, IP addresses, and SSH connection details.
        """

    static let inputSchema = MCPInputSchema(
        properties: [
            "filter": .string(description: "Filter by instance name, IP, region, or tags. Leave empty to list all."),
            "provider": .string(description: "Filter by provider ID: aws, azure, linode, digitalocean. Leave empty for all providers."),
            "limit": .integer(description: "Maximum number of results (default: 20)")
        ],
        required: nil
    )

    static let operationRisk: MCPOperationRisk = .safe

    @MainActor
    func execute(params: MCPToolCallParams, session: MCPSession) async throws -> MCPToolResult {
        let filter = params.stringArg("filter") ?? ""
        let providerFilter = params.stringArg("provider")?.lowercased()
        let limit = params.intArg("limit") ?? 20

        // Get all cached instances
        var instances = CloudCacheManager.shared.allInstances

        // Filter by provider if specified
        if let provider = providerFilter, !provider.isEmpty {
            instances = instances.filter { $0.providerID.lowercased() == provider }
        }

        // Filter by search query if specified
        if !filter.isEmpty {
            instances = instances.filter { $0.matches(query: filter) }
        }

        // Limit results
        let limitedInstances = Array(instances.prefix(limit))

        // Convert to response format
        let instanceList = limitedInstances.map { instance -> [String: Any] in
            var info: [String: Any] = [
                "name": instance.label,
                "provider": instance.providerID,
                "status": instance.status.rawValue,
                "canSSH": instance.canSSH
            ]

            // Include IP addresses for SSH
            if let ipv4 = instance.ipv4Address {
                info["ipv4"] = ipv4
            }
            if let hostname = instance.hostname {
                info["hostname"] = hostname
            }
            if let privateIP = instance.privateIP {
                info["privateIP"] = privateIP
            }

            // SSH connection hint
            if instance.canSSH, let sshHost = instance.sshHost {
                info["sshTarget"] = "\(instance.defaultSSHUsername)@\(sshHost)"
            }

            // Additional metadata
            if let region = instance.region {
                info["region"] = region
            }
            if let instanceType = instance.instanceType {
                info["instanceType"] = instanceType
            }
            if !instance.tags.isEmpty {
                info["tags"] = instance.tags
            }

            return info
        }

        if instanceList.isEmpty {
            if !filter.isEmpty {
                return .text("No cloud instances found matching '\(filter)'. Ensure cloud accounts are configured and instance cache is refreshed.")
            } else {
                return .text("No cloud instances found. Configure cloud accounts in Settings to see your VMs.")
            }
        }

        return .json(["instances": instanceList, "count": instanceList.count])
    }
}
