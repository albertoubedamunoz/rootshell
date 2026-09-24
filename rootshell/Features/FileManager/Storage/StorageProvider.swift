//
//  StorageProvider.swift
//  rootshell
//
//  A saved S3-compatible storage account. The whole config, credentials
//  included, lives in one iCloud Keychain item so it syncs across devices.
//

import Foundation

nonisolated struct StorageProvider: Codable, Identifiable, Hashable, Sendable {
    enum AddressingStyle: String, Codable, CaseIterable, Sendable {
        /// `https://endpoint/bucket/key`
        case path
        /// `https://bucket.endpoint/key`
        case virtualHost
    }

    var id = UUID()
    var name = ""
    var presetID = StorageProviderPreset.amazonS3.id
    var region = ""
    /// Account-specific endpoint part, for presets that ask for one.
    var accountID = ""
    /// Replaces the preset's endpoint; required for self-hosted servers.
    var customEndpoint = ""
    /// nil follows the preset.
    var addressingStyle: AddressingStyle?
    /// Overrides the region used in request signatures; empty follows the preset.
    var signingRegion = ""
    /// Empty for anonymous access to public buckets.
    var accessKeyID = ""
    var secretAccessKey = ""
    var sessionToken = ""
    /// Limits the provider to one bucket; empty lists every bucket.
    var bucket = ""
    /// Where a pane starts, relative to the provider's root.
    var initialPath = ""

    init() {}

    init(from decoder: Decoder) throws {
        // Tolerant decoding: items written by newer builds sync to older ones.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID) ?? StorageProviderPreset.custom.id
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint) ?? ""
        addressingStyle = try? container.decodeIfPresent(AddressingStyle.self, forKey: .addressingStyle)
        signingRegion = try container.decodeIfPresent(String.self, forKey: .signingRegion) ?? ""
        accessKeyID = try container.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        secretAccessKey = try container.decodeIfPresent(String.self, forKey: .secretAccessKey) ?? ""
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        initialPath = try container.decodeIfPresent(String.self, forKey: .initialPath) ?? ""
    }

    var preset: StorageProviderPreset {
        StorageProviderPreset.preset(for: presetID)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? preset.name : trimmed
    }

    /// Region used for signing and, for most presets, in the endpoint host.
    var effectiveRegion: String {
        let trimmed = region.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? preset.defaultRegion : trimmed
    }

    /// Region in the request signature. Usually the endpoint's region, but some
    /// Ceph-based services only accept a fixed one.
    var effectiveSigningRegion: String {
        let trimmed = signingRegion.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return preset.signingRegion ?? effectiveRegion
    }

    var effectiveBucket: String? {
        let trimmed = bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Full endpoint URL, or nil to let the SDK pick AWS's regional endpoint.
    var resolvedEndpoint: String? {
        let custom = customEndpoint.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let withScheme = custom.contains("://") ? custom : "https://" + custom
            return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
        }
        guard let template = preset.endpointTemplate else { return nil }
        let host = template
            .replacingOccurrences(of: "{region}", with: effectiveRegion)
            .replacingOccurrences(of: "{account}", with: accountID.trimmingCharacters(in: .whitespaces))
        return "https://" + host
    }

    var usesVirtualHost: Bool {
        (addressingStyle ?? preset.addressing) == .virtualHost
    }

    var isAnonymous: Bool {
        accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Why the config can't connect yet, or nil when complete.
    var validationError: String? {
        if preset.requiresCustomEndpoint, customEndpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter the server's endpoint.", comment: "Storage provider validation")
        }
        if let label = preset.accountIDLabel, customEndpoint.isEmpty, accountID.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter the \(label).", comment: "Storage provider validation; argument is a field name such as Account ID")
        }
        if let endpoint = resolvedEndpoint, URL(string: endpoint)?.host == nil {
            return String(localized: "The endpoint isn't a valid address.", comment: "Storage provider validation")
        }
        if !isAnonymous, secretAccessKey.isEmpty {
            return String(localized: "Enter the secret access key.", comment: "Storage provider validation")
        }
        return nil
    }

    /// True when both providers reach the same objects. Paths are always
    /// `/bucket/key`, so a bucket limit doesn't change what a path names.
    func reachesSameNamespace(as other: StorageProvider) -> Bool {
        endpointIdentity == other.endpointIdentity
    }

    /// The server as scheme, host, port and path, so two servers sharing a host
    /// name stay distinct. AWS bucket names are global within a partition.
    var endpointIdentity: String {
        guard let endpoint = resolvedEndpoint, let url = URL(string: endpoint), let host = url.host?.lowercased() else {
            return "aws:" + Self.awsPartition(of: effectiveRegion)
        }
        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return "\(scheme)://\(host):\(port)\(path)"
    }

    private static func awsPartition(of region: String) -> String {
        if region.hasPrefix("cn-") { return "aws-cn" }
        if region.hasPrefix("us-gov-") { return "aws-us-gov" }
        if region.hasPrefix("us-isob-") { return "aws-iso-b" }
        if region.hasPrefix("us-iso-") { return "aws-iso" }
        return "aws"
    }
}
