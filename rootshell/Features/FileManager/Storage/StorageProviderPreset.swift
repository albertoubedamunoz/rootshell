//
//  StorageProviderPreset.swift
//  rootshell
//
//  Endpoint and addressing defaults for common S3-compatible services, so a
//  new provider usually needs only a region and a key pair.
//

import Foundation

nonisolated struct StorageProviderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Endpoint host; `{region}` and `{account}` are substituted. nil means
    /// AWS's own regional endpoints, or a user-supplied endpoint.
    let endpointTemplate: String?
    /// Suggested regions; any value may be typed.
    let regions: [String]
    let defaultRegion: String
    let addressing: StorageProvider.AddressingStyle
    /// Field name for the `{account}` part of the endpoint.
    var accountIDLabel: String? = nil
    var isAWS = false
    /// DeleteObjects (batch delete) is available.
    var supportsBatchDelete = true
    /// Region in the request signature when the service expects a fixed one
    /// rather than the endpoint's region.
    var signingRegion: String? = nil

    /// Favicon domain when the endpoint host isn't known ahead of time.
    var websiteDomain: String? = nil

    var requiresCustomEndpoint: Bool { endpointTemplate == nil && !isAWS }
    var showsRegion: Bool { regions.count != 1 }

    /// Favicon domain for the service as a whole, before any account details.
    var faviconDomain: String? {
        if isAWS { return StorageFaviconDomains.domain(forEndpointHost: "s3.amazonaws.com") }
        guard let endpointTemplate else { return websiteDomain }
        let host = endpointTemplate
            .replacingOccurrences(of: "{region}", with: defaultRegion)
            .replacingOccurrences(of: "{account}", with: "account")
        return StorageFaviconDomains.domain(forEndpointHost: host)
    }

    static func preset(for id: String) -> StorageProviderPreset {
        all.first { $0.id == id } ?? custom
    }

    static let amazonS3 = StorageProviderPreset(
        id: "aws", name: "Amazon S3", endpointTemplate: nil,
        regions: [
            "us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "ca-west-1",
            "sa-east-1", "mx-central-1", "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
            "eu-central-2", "eu-north-1", "eu-south-1", "eu-south-2", "il-central-1", "me-south-1",
            "me-central-1", "af-south-1", "ap-east-1", "ap-south-1", "ap-south-2", "ap-northeast-1",
            "ap-northeast-2", "ap-northeast-3", "ap-southeast-1", "ap-southeast-2", "ap-southeast-3",
            "ap-southeast-4", "ap-southeast-5", "ap-southeast-7", "us-gov-west-1", "us-gov-east-1",
            "cn-north-1", "cn-northwest-1",
        ],
        defaultRegion: "us-east-1", addressing: .virtualHost, isAWS: true
    )

    static let custom = StorageProviderPreset(
        id: "custom", name: String(localized: "S3-Compatible Server", comment: "Storage provider preset: self-hosted S3 such as MinIO or Ceph"),
        endpointTemplate: nil, regions: [], defaultRegion: "us-east-1", addressing: .path
    )

    static let all: [StorageProviderPreset] = [
        amazonS3,
        StorageProviderPreset(
            id: "r2", name: "Cloudflare R2", endpointTemplate: "{account}.r2.cloudflarestorage.com",
            regions: ["auto"], defaultRegion: "auto", addressing: .path,
            accountIDLabel: String(localized: "Account ID", comment: "Storage provider field: Cloudflare account ID")
        ),
        StorageProviderPreset(
            id: "b2", name: "Backblaze B2", endpointTemplate: "s3.{region}.backblazeb2.com",
            regions: ["us-west-000", "us-west-001", "us-west-002", "us-west-004", "us-east-005", "eu-central-003", "ca-east-006"],
            defaultRegion: "us-west-004", addressing: .path
        ),
        StorageProviderPreset(
            id: "wasabi", name: "Wasabi", endpointTemplate: "s3.{region}.wasabisys.com",
            regions: [
                "us-east-1", "us-east-2", "us-central-1", "us-west-1", "us-west-2", "ca-central-1",
                "eu-central-1", "eu-central-2", "eu-west-1", "eu-west-2", "eu-west-3", "eu-south-1",
                "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2",
            ],
            defaultRegion: "us-east-1", addressing: .path
        ),
        StorageProviderPreset(
            id: "digitalocean", name: "DigitalOcean Spaces", endpointTemplate: "{region}.digitaloceanspaces.com",
            regions: ["nyc3", "sfo2", "sfo3", "ams3", "fra1", "lon1", "tor1", "sgp1", "syd1", "blr1", "atl1"],
            defaultRegion: "nyc3", addressing: .path
        ),
        StorageProviderPreset(
            id: "linode", name: "Akamai (Linode) Object Storage", endpointTemplate: "{region}.linodeobjects.com",
            regions: [
                "us-east-1", "us-southeast-1", "us-iad-1", "us-ord-1", "us-sea-1", "us-mia-1", "us-lax-1",
                "eu-central-1", "fr-par-1", "se-sto-1", "it-mil-1", "es-mad-1", "nl-ams-1", "gb-lon-1",
                "ap-south-1", "in-maa-1", "jp-osa-1", "id-cgk-1", "br-gru-1", "au-mel-1",
            ],
            defaultRegion: "us-east-1", addressing: .path, signingRegion: "us-east-1"
        ),
        StorageProviderPreset(
            id: "gcs", name: "Google Cloud Storage", endpointTemplate: "storage.googleapis.com",
            regions: ["auto"], defaultRegion: "auto", addressing: .path, supportsBatchDelete: false
        ),
        StorageProviderPreset(
            id: "hetzner", name: "Hetzner Object Storage", endpointTemplate: "{region}.your-objectstorage.com",
            regions: ["fsn1", "nbg1", "hel1"], defaultRegion: "fsn1", addressing: .path
        ),
        StorageProviderPreset(
            id: "scaleway", name: "Scaleway Object Storage", endpointTemplate: "s3.{region}.scw.cloud",
            regions: ["fr-par", "nl-ams", "pl-waw"], defaultRegion: "fr-par", addressing: .path
        ),
        StorageProviderPreset(
            id: "ovh", name: "OVHcloud Object Storage", endpointTemplate: "s3.{region}.io.cloud.ovh.net",
            regions: ["gra", "sbg", "rbx", "bhs", "de", "uk", "waw"], defaultRegion: "gra", addressing: .path
        ),
        StorageProviderPreset(
            id: "exoscale", name: "Exoscale SOS", endpointTemplate: "sos-{region}.exo.io",
            regions: ["ch-gva-2", "ch-dk-2", "de-fra-1", "de-muc-1", "at-vie-1", "at-vie-2", "bg-sof-1"],
            defaultRegion: "ch-gva-2", addressing: .path
        ),
        StorageProviderPreset(
            id: "vultr", name: "Vultr Object Storage", endpointTemplate: "{region}.vultrobjects.com",
            regions: ["ewr1", "sjc1", "ams1", "blr1", "del1", "sgp1"], defaultRegion: "ewr1", addressing: .path
        ),
        StorageProviderPreset(
            id: "oracle", name: "Oracle Cloud Object Storage", endpointTemplate: "{account}.compat.objectstorage.{region}.oraclecloud.com",
            regions: [
                "us-ashburn-1", "us-phoenix-1", "us-sanjose-1", "us-chicago-1", "ca-toronto-1", "sa-saopaulo-1",
                "uk-london-1", "eu-frankfurt-1", "eu-amsterdam-1", "eu-zurich-1", "ap-tokyo-1", "ap-osaka-1",
                "ap-sydney-1", "ap-mumbai-1", "ap-singapore-1",
            ],
            defaultRegion: "us-ashburn-1", addressing: .path,
            accountIDLabel: String(localized: "Namespace", comment: "Storage provider field: Oracle Cloud object storage namespace")
        ),
        StorageProviderPreset(
            id: "ibm", name: "IBM Cloud Object Storage", endpointTemplate: "s3.{region}.cloud-object-storage.appdomain.cloud",
            regions: ["us-south", "us-east", "ca-tor", "br-sao", "eu-gb", "eu-de", "eu-es", "jp-tok", "jp-osa", "au-syd"],
            defaultRegion: "us-south", addressing: .path
        ),
        StorageProviderPreset(
            id: "contabo", name: "Contabo Object Storage", endpointTemplate: "{region}.contabostorage.com",
            regions: ["eu2", "usc1", "sin1"], defaultRegion: "eu2", addressing: .path
        ),
        StorageProviderPreset(
            id: "synology", name: "Synology C2 Object Storage", endpointTemplate: "{region}.s3.synologyc2.net",
            regions: ["us-001", "eu-002", "tw-001"], defaultRegion: "us-001", addressing: .path
        ),
        StorageProviderPreset(
            id: "storj", name: "Storj", endpointTemplate: "gateway.storjshare.io",
            regions: ["us-east-1"], defaultRegion: "us-east-1", addressing: .path
        ),
        StorageProviderPreset(
            id: "filebase", name: "Filebase", endpointTemplate: "s3.filebase.com",
            regions: ["us-east-1"], defaultRegion: "us-east-1", addressing: .path
        ),
        StorageProviderPreset(
            id: "tigris", name: "Tigris", endpointTemplate: "t3.storageapi.dev",
            regions: ["auto"], defaultRegion: "auto", addressing: .path
        ),
        StorageProviderPreset(
            id: "idrive", name: "IDrive e2", endpointTemplate: nil,
            regions: [], defaultRegion: "us-east-1", addressing: .path, websiteDomain: "idrive.com"
        ),
        custom,
    ]
}

/// S3 API hosts answer every path, favicon included, with an XML error, so
/// known endpoint domains map to their operator's website instead.
nonisolated enum StorageFaviconDomains {
    /// Endpoint domain suffix → website domain with a fetchable favicon. A label
    /// ending in `*` matches by prefix (IDrive numbers its e2 domains).
    static let fallbacks: [(endpoint: String, website: String)] = [
        ("amazonaws.com", "aws.amazon.com"),
        ("amazonaws.com.cn", "aws.amazon.com"),
        ("cloudflarestorage.com", "cloudflare.com"),
        ("backblazeb2.com", "backblaze.com"),
        ("wasabisys.com", "wasabi.com"),
        ("digitaloceanspaces.com", "digitalocean.com"),
        ("linodeobjects.com", "akamai.com"),
        ("storage.googleapis.com", "cloud.google.com"),
        ("your-objectstorage.com", "hetzner.com"),
        ("scw.cloud", "scaleway.com"),
        ("cloud.ovh.net", "ovhcloud.com"),
        ("exo.io", "exoscale.com"),
        ("vultrobjects.com", "vultr.com"),
        ("oraclecloud.com", "oracle.com"),
        ("appdomain.cloud", "ibm.com"),
        ("contabostorage.com", "contabo.com"),
        ("synologyc2.net", "synology.com"),
        ("storjshare.io", "docs.storj.io"),
        ("filebase.com", "console.filebase.com"),
        ("storageapi.dev", "tigrisdata.com"),
        ("tigris.dev", "tigrisdata.com"),
        ("idrivee2-*.com", "idrive.com"),
        ("aliyuncs.com", "alibabacloud.com"),
        ("myqcloud.com", "tencentcloud.com"),
    ]

    /// The domain to fetch a favicon from for an endpoint host, or nil for
    /// addresses with no public website (IPs, single-label and `.local` names).
    static func domain(forEndpointHost host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard host.contains("."), !host.hasSuffix(".local"), !isIPAddress(host) else { return nil }
        let labels = host.split(separator: ".")
        for fallback in fallbacks where matches(labels, fallback.endpoint) {
            return fallback.website
        }
        return host
    }

    private static func matches(_ hostLabels: [Substring], _ pattern: String) -> Bool {
        let patternLabels = pattern.split(separator: ".")
        guard hostLabels.count >= patternLabels.count else { return false }
        return zip(hostLabels.suffix(patternLabels.count), patternLabels).allSatisfy { label, patternLabel in
            patternLabel.hasSuffix("*") ? label.hasPrefix(patternLabel.dropLast()) : label == patternLabel
        }
    }

    private static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}
