#if !CHINA_BUILD
//
//  BedrockRegions.swift
//  rootshell
//
//  AWS regions where Amazon Bedrock + Anthropic Claude models are available,
//  plus the geography prefix used for cross-region inference profile IDs
//  (e.g., us.anthropic.claude-opus-5-v1:0 in any us-* region).
//

import Foundation

enum BedrockRegions {
    /// Region where the user wants Bedrock invocations terminated.
    /// Subset of `AWSProvider.regions` — Bedrock is not available in every AWS region.
    static let regions: [AWSProvider.Region] = [
        // United States
        AWSProvider.Region(id: "us-east-1", name: "US East", description: "N. Virginia"),
        AWSProvider.Region(id: "us-east-2", name: "US East", description: "Ohio"),
        AWSProvider.Region(id: "us-west-2", name: "US West", description: "Oregon"),

        // Europe
        AWSProvider.Region(id: "eu-central-1", name: "Europe", description: "Frankfurt"),
        AWSProvider.Region(id: "eu-west-1", name: "Europe", description: "Ireland"),
        AWSProvider.Region(id: "eu-west-2", name: "Europe", description: "London"),
        AWSProvider.Region(id: "eu-west-3", name: "Europe", description: "Paris"),
        AWSProvider.Region(id: "eu-north-1", name: "Europe", description: "Stockholm"),

        // Asia Pacific
        AWSProvider.Region(id: "ap-northeast-1", name: "Asia Pacific", description: "Tokyo"),
        AWSProvider.Region(id: "ap-northeast-2", name: "Asia Pacific", description: "Seoul"),
        AWSProvider.Region(id: "ap-southeast-1", name: "Asia Pacific", description: "Singapore"),
        AWSProvider.Region(id: "ap-southeast-2", name: "Asia Pacific", description: "Sydney"),
        AWSProvider.Region(id: "ap-south-1", name: "Asia Pacific", description: "Mumbai"),

        // Other
        AWSProvider.Region(id: "ca-central-1", name: "Canada", description: "Central"),
        AWSProvider.Region(id: "sa-east-1", name: "South America", description: "São Paulo")
    ]

    /// Default region for first-time configuration.
    nonisolated static let defaultRegion = "us-east-1"

    /// Returns true if the given AWS region ID is in our Bedrock-supported list.
    static func isSupported(_ regionID: String) -> Bool {
        regions.contains { $0.id == regionID }
    }

    /// Display string used in the picker, e.g., "US East (N. Virginia)".
    static func displayName(for regionID: String) -> String {
        if let region = regions.first(where: { $0.id == regionID }) {
            return "\(region.name) (\(region.description))"
        }
        return regionID
    }
}
#endif
