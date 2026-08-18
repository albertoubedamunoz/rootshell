import Foundation

// MARK: - Ubiquiti API Response Models

nonisolated struct UbiquitiDevicesResponse: Codable, Sendable {
    let data: [UbiquitiHost]
    let nextToken: String?
}

nonisolated struct UbiquitiHost: Codable, Sendable {
    let hostId: String
    let hostName: String
    let devices: [UbiquitiDevice]
}

nonisolated struct UbiquitiDevice: Codable, Sendable {
    let id: String
    let mac: String
    let name: String
    let model: String?
    let shortname: String?
    let ip: String?
    let productLine: String?
    let status: String?

    /// Convert to our canonical WiFiAccessPoint model
    func toAccessPoint(accountID: UUID, hostId: String, siteName: String?) -> WiFiAccessPoint {
        WiFiAccessPoint(
            id: id,
            accountID: accountID,
            providerID: UbiquitiProvider.providerID,
            name: name,
            mac: normalizeMAC(mac),
            model: model,
            shortname: shortname,
            ip: ip,
            productLine: productLine,
            status: status,
            siteName: siteName,
            hostId: hostId,
            siteId: nil,
            lastUpdated: Date()
        )
    }

    /// Normalize MAC to uppercase colon-separated format
    private func normalizeMAC(_ raw: String) -> String {
        MACAddress(raw)?.canonicalString ?? raw.uppercased()
    }
}

// MARK: - Network API Sites Response (via cloud connector proxy)

nonisolated struct UbiquitiNetworkSitesResponse: Decodable, Sendable {
    let data: [UbiquitiNetworkSite]
}

nonisolated struct UbiquitiNetworkSite: Decodable, Sendable {
    let id: String
    let name: String?
}

// MARK: - Network API Devices Response (via cloud connector proxy)

nonisolated struct UbiquitiNetworkDevicesResponse: Decodable, Sendable {
    let data: [UbiquitiNetworkDevice]
}

nonisolated struct UbiquitiNetworkDevice: Decodable, Sendable {
    let macAddress: String
    let features: [String]

    var isAccessPoint: Bool { features.contains("accessPoint") }
}

