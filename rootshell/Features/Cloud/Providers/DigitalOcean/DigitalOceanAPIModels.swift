@preconcurrency import Foundation

// MARK: - DigitalOcean API Response Models

/// Response wrapper for droplets list
struct DigitalOceanDropletsResponse: Sendable {
    let droplets: [DigitalOceanDropletResponse]
    let meta: DigitalOceanMetaResponse?
    let links: DigitalOceanLinksResponse?
}

extension DigitalOceanDropletsResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        droplets = try container.decode([DigitalOceanDropletResponse].self, forKey: .droplets)
        meta = try container.decodeIfPresent(DigitalOceanMetaResponse.self, forKey: .meta)
        links = try container.decodeIfPresent(DigitalOceanLinksResponse.self, forKey: .links)
    }
    private enum CodingKeys: String, CodingKey {
        case droplets, meta, links
    }
}

/// Response wrapper for single droplet
struct DigitalOceanDropletWrapper: Sendable {
    let droplet: DigitalOceanDropletResponse
}

extension DigitalOceanDropletWrapper: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        droplet = try container.decode(DigitalOceanDropletResponse.self, forKey: .droplet)
    }
    private enum CodingKeys: String, CodingKey {
        case droplet
    }
}

/// Pagination metadata
struct DigitalOceanMetaResponse: Sendable {
    let total: Int
}

extension DigitalOceanMetaResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
    }
    private enum CodingKeys: String, CodingKey {
        case total
    }
}

/// Pagination links
struct DigitalOceanLinksResponse: Sendable {
    let pages: DigitalOceanPagesResponse?
}

extension DigitalOceanLinksResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pages = try container.decodeIfPresent(DigitalOceanPagesResponse.self, forKey: .pages)
    }
    private enum CodingKeys: String, CodingKey {
        case pages
    }
}

/// Page navigation links
struct DigitalOceanPagesResponse: Sendable {
    let first: String?
    let prev: String?
    let next: String?
    let last: String?
}

extension DigitalOceanPagesResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        first = try container.decodeIfPresent(String.self, forKey: .first)
        prev = try container.decodeIfPresent(String.self, forKey: .prev)
        next = try container.decodeIfPresent(String.self, forKey: .next)
        last = try container.decodeIfPresent(String.self, forKey: .last)
    }
    private enum CodingKeys: String, CodingKey {
        case first, prev, next, last
    }
}

// MARK: - Account Info

/// DigitalOcean account information wrapper
struct DigitalOceanAccountWrapper: Sendable {
    let account: DigitalOceanAccountResponse
}

extension DigitalOceanAccountWrapper: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(DigitalOceanAccountResponse.self, forKey: .account)
    }
    private enum CodingKeys: String, CodingKey {
        case account
    }
}

/// DigitalOcean account information response
struct DigitalOceanAccountResponse: Sendable {
    let dropletLimit: Int?
    let floatingIpLimit: Int?
    let email: String
    let uuid: String
    let emailVerified: Bool?
    let status: String?
    let statusMessage: String?
    let team: DigitalOceanTeamResponse?

    /// Convert to generic ProviderAccountInfo
    nonisolated func toProviderAccountInfo() -> ProviderAccountInfo {
        return ProviderAccountInfo(
            accountID: uuid,
            displayName: team?.name ?? email,
            email: email,
            company: team?.name
        )
    }
}

extension DigitalOceanAccountResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dropletLimit = try container.decodeIfPresent(Int.self, forKey: .dropletLimit)
        floatingIpLimit = try container.decodeIfPresent(Int.self, forKey: .floatingIpLimit)
        email = try container.decode(String.self, forKey: .email)
        uuid = try container.decode(String.self, forKey: .uuid)
        emailVerified = try container.decodeIfPresent(Bool.self, forKey: .emailVerified)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        team = try container.decodeIfPresent(DigitalOceanTeamResponse.self, forKey: .team)
    }
    private enum CodingKeys: String, CodingKey {
        case dropletLimit = "droplet_limit"
        case floatingIpLimit = "floating_ip_limit"
        case email, uuid
        case emailVerified = "email_verified"
        case status
        case statusMessage = "status_message"
        case team
    }
}

/// DigitalOcean team information
struct DigitalOceanTeamResponse: Sendable {
    let name: String?
    let uuid: String?
}

extension DigitalOceanTeamResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
    }
    private enum CodingKeys: String, CodingKey {
        case name, uuid
    }
}

// MARK: - Droplets (Instances)

/// DigitalOcean droplet response
struct DigitalOceanDropletResponse: Sendable {
    let id: Int
    let name: String
    let memory: Int
    let vcpus: Int
    let disk: Int
    let locked: Bool
    let status: String
    let createdAt: String
    let features: [String]
    let backupIds: [Int]?
    let snapshotIds: [Int]?
    let image: DigitalOceanImageResponse?
    let size: DigitalOceanSizeResponse?
    let sizeSlug: String?
    let networks: DigitalOceanNetworksResponse?
    let region: DigitalOceanRegionResponse?
    let tags: [String]
    let vpcUuid: String?

    /// Convert to provider-agnostic CloudInstance
    nonisolated func toCloudInstance(accountID: UUID) -> CloudInstance {
        var instance = CloudInstance(
            accountID: accountID,
            providerInstanceID: String(id),
            providerID: DigitalOceanProvider.providerID,
            label: name,
            status: mapStatus(status)
        )

        // Extract public IPv4 address
        if let networks = networks {
            instance.ipv4Address = networks.v4?.first(where: { $0.type == "public" })?.ipAddress
            instance.privateIP = networks.v4?.first(where: { $0.type == "private" })?.ipAddress
            instance.ipv6Address = networks.v6?.first(where: { $0.type == "public" })?.ipAddress
        }

        instance.region = region?.slug
        instance.instanceType = sizeSlug ?? size?.slug
        instance.image = image?.slug ?? image?.name
        instance.tags = tags
        instance.lastUpdated = Date()

        return instance
    }

    private nonisolated func mapStatus(_ status: String) -> CloudInstanceStatus {
        switch status.lowercased() {
        case "active": return .running
        case "new": return .provisioning
        case "off", "archive": return .stopped
        case "in-progress": return .provisioning
        default: return .unknown
        }
    }
}

extension DigitalOceanDropletResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        memory = try container.decode(Int.self, forKey: .memory)
        vcpus = try container.decode(Int.self, forKey: .vcpus)
        disk = try container.decode(Int.self, forKey: .disk)
        locked = try container.decode(Bool.self, forKey: .locked)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        features = try container.decode([String].self, forKey: .features)
        backupIds = try container.decodeIfPresent([Int].self, forKey: .backupIds)
        snapshotIds = try container.decodeIfPresent([Int].self, forKey: .snapshotIds)
        image = try container.decodeIfPresent(DigitalOceanImageResponse.self, forKey: .image)
        size = try container.decodeIfPresent(DigitalOceanSizeResponse.self, forKey: .size)
        sizeSlug = try container.decodeIfPresent(String.self, forKey: .sizeSlug)
        networks = try container.decodeIfPresent(DigitalOceanNetworksResponse.self, forKey: .networks)
        region = try container.decodeIfPresent(DigitalOceanRegionResponse.self, forKey: .region)
        tags = try container.decode([String].self, forKey: .tags)
        vpcUuid = try container.decodeIfPresent(String.self, forKey: .vpcUuid)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, memory, vcpus, disk, locked, status
        case createdAt = "created_at"
        case features
        case backupIds = "backup_ids"
        case snapshotIds = "snapshot_ids"
        case image, size
        case sizeSlug = "size_slug"
        case networks, region, tags
        case vpcUuid = "vpc_uuid"
    }
}

/// DigitalOcean image information
struct DigitalOceanImageResponse: Sendable {
    let id: Int
    let name: String?
    let distribution: String?
    let slug: String?
    let isPublic: Bool?
    let regions: [String]?
    let createdAt: String?
    let type: String?
    let minDiskSize: Int?
    let sizeGigabytes: Double?
}

extension DigitalOceanImageResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        distribution = try container.decodeIfPresent(String.self, forKey: .distribution)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic)
        regions = try container.decodeIfPresent([String].self, forKey: .regions)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        minDiskSize = try container.decodeIfPresent(Int.self, forKey: .minDiskSize)
        sizeGigabytes = try container.decodeIfPresent(Double.self, forKey: .sizeGigabytes)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, distribution, slug
        case isPublic = "public"
        case regions
        case createdAt = "created_at"
        case type
        case minDiskSize = "min_disk_size"
        case sizeGigabytes = "size_gigabytes"
    }
}

/// DigitalOcean size/plan information
struct DigitalOceanSizeResponse: Sendable {
    let slug: String
    let memory: Int?
    let vcpus: Int?
    let disk: Int?
    let transfer: Double?
    let priceMonthly: Double?
    let priceHourly: Double?
    let regions: [String]?
}

extension DigitalOceanSizeResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        memory = try container.decodeIfPresent(Int.self, forKey: .memory)
        vcpus = try container.decodeIfPresent(Int.self, forKey: .vcpus)
        disk = try container.decodeIfPresent(Int.self, forKey: .disk)
        transfer = try container.decodeIfPresent(Double.self, forKey: .transfer)
        priceMonthly = try container.decodeIfPresent(Double.self, forKey: .priceMonthly)
        priceHourly = try container.decodeIfPresent(Double.self, forKey: .priceHourly)
        regions = try container.decodeIfPresent([String].self, forKey: .regions)
    }
    private enum CodingKeys: String, CodingKey {
        case slug, memory, vcpus, disk, transfer
        case priceMonthly = "price_monthly"
        case priceHourly = "price_hourly"
        case regions
    }
}

/// DigitalOcean networks container
struct DigitalOceanNetworksResponse: Sendable {
    let v4: [DigitalOceanIPv4Response]?
    let v6: [DigitalOceanIPv6Response]?
}

extension DigitalOceanNetworksResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v4 = try container.decodeIfPresent([DigitalOceanIPv4Response].self, forKey: .v4)
        v6 = try container.decodeIfPresent([DigitalOceanIPv6Response].self, forKey: .v6)
    }
    private enum CodingKeys: String, CodingKey {
        case v4, v6
    }
}

/// IPv4 address information
struct DigitalOceanIPv4Response: Sendable {
    let ipAddress: String
    let netmask: String?
    let gateway: String?
    let type: String
}

extension DigitalOceanIPv4Response: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        netmask = try container.decodeIfPresent(String.self, forKey: .netmask)
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        type = try container.decode(String.self, forKey: .type)
    }
    private enum CodingKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case netmask, gateway, type
    }
}

/// IPv6 address information
struct DigitalOceanIPv6Response: Sendable {
    let ipAddress: String
    let netmask: Int?
    let gateway: String?
    let type: String
}

extension DigitalOceanIPv6Response: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        netmask = try container.decodeIfPresent(Int.self, forKey: .netmask)
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        type = try container.decode(String.self, forKey: .type)
    }
    private enum CodingKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case netmask, gateway, type
    }
}

/// DigitalOcean region information
struct DigitalOceanRegionResponse: Sendable {
    let name: String?
    let slug: String
    let features: [String]?
    let available: Bool?
    let sizes: [String]?
}

extension DigitalOceanRegionResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        features = try container.decodeIfPresent([String].self, forKey: .features)
        available = try container.decodeIfPresent(Bool.self, forKey: .available)
        sizes = try container.decodeIfPresent([String].self, forKey: .sizes)
    }
    private enum CodingKeys: String, CodingKey {
        case name, slug, features, available, sizes
    }
}

// MARK: - Kubernetes (DOKS) Clusters

/// Response wrapper for Kubernetes clusters list
struct DigitalOceanKubernetesClustersResponse: Sendable {
    let kubernetesClusters: [DigitalOceanKubernetesClusterResponse]
    let meta: DigitalOceanMetaResponse?
    let links: DigitalOceanLinksResponse?
}

extension DigitalOceanKubernetesClustersResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kubernetesClusters = try container.decode([DigitalOceanKubernetesClusterResponse].self, forKey: .kubernetesClusters)
        meta = try container.decodeIfPresent(DigitalOceanMetaResponse.self, forKey: .meta)
        links = try container.decodeIfPresent(DigitalOceanLinksResponse.self, forKey: .links)
    }
    private enum CodingKeys: String, CodingKey {
        case kubernetesClusters = "kubernetes_clusters"
        case meta, links
    }
}

/// DigitalOcean Kubernetes cluster response
struct DigitalOceanKubernetesClusterResponse: Sendable {
    let id: String
    let name: String
    let region: String
    let version: String
    let clusterSubnet: String?
    let serviceSubnet: String?
    let ipv4: String?
    let endpoint: String?
    let ha: Bool?
    let autoUpgrade: Bool?
    let surgeUpgrade: Bool?
    let registryEnabled: Bool?
    let tags: [String]?
    let vpcUuid: String?
    let status: DigitalOceanClusterStatusResponse?
    let createdAt: String?
    let updatedAt: String?
    let nodePools: [DigitalOceanNodePoolResponse]?

    /// Convert to provider-agnostic CloudKubernetesCluster
    nonisolated func toCloudKubernetesCluster(accountID: UUID) -> CloudKubernetesCluster {
        var cluster = CloudKubernetesCluster(
            accountID: accountID,
            providerClusterID: id,
            providerID: DigitalOceanProvider.providerID,
            label: name,
            status: mapStatus(status?.state)
        )

        cluster.kubernetesVersion = version
        cluster.region = region
        cluster.apiEndpoint = endpoint
        cluster.highAvailability = ha ?? false
        cluster.tags = tags ?? []
        cluster.nodeCount = nodePools?.reduce(0) { $0 + $1.count } ?? 0
        cluster.lastUpdated = Date()

        return cluster
    }

    private nonisolated func mapStatus(_ state: String?) -> CloudClusterStatus {
        guard let state = state?.lowercased() else { return .unknown }
        switch state {
        case "running": return .ready
        case "provisioning": return .provisioning
        case "degraded": return .notReady
        case "error", "invalid": return .notReady
        case "upgrading": return .upgrading
        case "deleting", "deleted": return .deleting
        default: return .unknown
        }
    }
}

extension DigitalOceanKubernetesClusterResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        region = try container.decode(String.self, forKey: .region)
        version = try container.decode(String.self, forKey: .version)
        clusterSubnet = try container.decodeIfPresent(String.self, forKey: .clusterSubnet)
        serviceSubnet = try container.decodeIfPresent(String.self, forKey: .serviceSubnet)
        ipv4 = try container.decodeIfPresent(String.self, forKey: .ipv4)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        ha = try container.decodeIfPresent(Bool.self, forKey: .ha)
        autoUpgrade = try container.decodeIfPresent(Bool.self, forKey: .autoUpgrade)
        surgeUpgrade = try container.decodeIfPresent(Bool.self, forKey: .surgeUpgrade)
        registryEnabled = try container.decodeIfPresent(Bool.self, forKey: .registryEnabled)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        vpcUuid = try container.decodeIfPresent(String.self, forKey: .vpcUuid)
        status = try container.decodeIfPresent(DigitalOceanClusterStatusResponse.self, forKey: .status)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        nodePools = try container.decodeIfPresent([DigitalOceanNodePoolResponse].self, forKey: .nodePools)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, region, version
        case clusterSubnet = "cluster_subnet"
        case serviceSubnet = "service_subnet"
        case ipv4, endpoint, ha
        case autoUpgrade = "auto_upgrade"
        case surgeUpgrade = "surge_upgrade"
        case registryEnabled = "registry_enabled"
        case tags
        case vpcUuid = "vpc_uuid"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case nodePools = "node_pools"
    }
}

/// Cluster status information
struct DigitalOceanClusterStatusResponse: Sendable {
    let state: String?
    let message: String?
}

extension DigitalOceanClusterStatusResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
    private enum CodingKeys: String, CodingKey {
        case state, message
    }
}

/// Node pool information
struct DigitalOceanNodePoolResponse: Sendable {
    let id: String?
    let name: String?
    let size: String?
    let count: Int
    let tags: [String]?
    let labels: [String: String]?
    let autoScale: Bool?
    let minNodes: Int?
    let maxNodes: Int?
    let nodes: [DigitalOceanNodeResponse]?
}

extension DigitalOceanNodePoolResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        size = try container.decodeIfPresent(String.self, forKey: .size)
        count = try container.decode(Int.self, forKey: .count)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
        autoScale = try container.decodeIfPresent(Bool.self, forKey: .autoScale)
        minNodes = try container.decodeIfPresent(Int.self, forKey: .minNodes)
        maxNodes = try container.decodeIfPresent(Int.self, forKey: .maxNodes)
        nodes = try container.decodeIfPresent([DigitalOceanNodeResponse].self, forKey: .nodes)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, size, count, tags, labels
        case autoScale = "auto_scale"
        case minNodes = "min_nodes"
        case maxNodes = "max_nodes"
        case nodes
    }
}

/// Individual node information
struct DigitalOceanNodeResponse: Sendable {
    let id: String?
    let name: String?
    let status: DigitalOceanNodeStatusResponse?
    let dropletId: String?
    let createdAt: String?
    let updatedAt: String?
}

extension DigitalOceanNodeResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decodeIfPresent(DigitalOceanNodeStatusResponse.self, forKey: .status)
        dropletId = try container.decodeIfPresent(String.self, forKey: .dropletId)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, status
        case dropletId = "droplet_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Node status information
struct DigitalOceanNodeStatusResponse: Sendable {
    let state: String?
}

extension DigitalOceanNodeStatusResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
    }
    private enum CodingKeys: String, CodingKey {
        case state
    }
}

// MARK: - Kubeconfig

/// Note: DigitalOcean returns kubeconfig as raw YAML, not JSON wrapped.
/// The API client handles this differently than other responses.

// MARK: - Error Response

/// DigitalOcean API error response
struct DigitalOceanErrorResponse: Sendable {
    let id: String?
    let message: String
    let requestId: String?
}

extension DigitalOceanErrorResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        message = try container.decode(String.self, forKey: .message)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
    }
    private enum CodingKeys: String, CodingKey {
        case id, message
        case requestId = "request_id"
    }
}
