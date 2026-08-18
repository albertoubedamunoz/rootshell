import Foundation
import os.log

// MARK: - Ubiquiti API Client

actor UbiquitiAPIClient: WiFiAPProviderAPIClient {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "UbiquitiAPIClient")

    private let credentials: WiFiAPCredentials
    private let accountID: UUID
    private let baseURL = URL(string: "https://api.ui.com/v1")!
    private let urlSession: URLSession

    init(credentials: WiFiAPCredentials, accountID: UUID) {
        self.credentials = credentials
        self.accountID = accountID

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - WiFiAPProviderAPIClient

    func validateCredentials() async throws -> Bool {
        // Try to list devices - if we get a valid response, credentials are good
        _ = try await fetchDevicesPage(nextToken: nil)
        return true
    }

    func listAccessPoints() async throws -> [WiFiAccessPoint] {
        var allAPs: [WiFiAccessPoint] = []
        var nextToken: String? = nil

        repeat {
            let response = try await fetchDevicesPage(nextToken: nextToken)

            for host in response.data {
                let aps = host.devices
                    .filter { $0.productLine == "network" }
                    .map { $0.toAccessPoint(accountID: accountID, hostId: host.hostId, siteName: host.hostName) }
                allAPs.append(contentsOf: aps)
            }

            nextToken = response.nextToken
        } while nextToken != nil

        Self.logger.info("Fetched \(allAPs.count) devices from Ubiquiti Site Manager API")

        // Enrich with siteId and isWirelessAP from Network API
        allAPs = await enrichWithNetworkAPI(devices: allAPs)

        return allAPs
    }

    /// Query the Network API via cloud connector to get device features (accessPoint, switching, gateway)
    /// and site IDs, then enrich the device list.
    private func enrichWithNetworkAPI(devices: [WiFiAccessPoint]) async -> [WiFiAccessPoint] {
        guard credentials.apiKey != nil else { return devices }

        // Group devices by hostId to minimize API calls
        var devicesByHost: [String: [WiFiAccessPoint]] = [:]
        for device in devices {
            guard let hostId = device.hostId else { continue }
            devicesByHost[hostId, default: []].append(device)
        }

        let hostCount = devicesByHost.count
        Self.logger.info("Enrichment: \(devices.count) devices across \(hostCount) hosts")
        guard !devicesByHost.isEmpty else {
            Self.logger.warning("Enrichment: no devices have hostId set, skipping")
            return devices
        }

        // For each console (hostId), fetch sites via the Network API connector,
        // then fetch devices with features. The Network API has its own siteId format
        // (UUID) different from the Site Manager API (MongoDB ObjectId).
        var isAPByMAC: [String: Bool] = [:]
        for (consoleId, _) in devicesByHost {
            // Fetch sites for this console via Network API connector
            let networkSites: [UbiquitiNetworkSite]
            do {
                networkSites = try await fetchNetworkSites(consoleId: consoleId)
                let siteCount = networkSites.count
                Self.logger.info("Console \(consoleId): \(siteCount) Network API site(s)")
            } catch {
                Self.logger.error("Failed to fetch Network API sites for \(consoleId): \(error)")
                continue
            }

            // Fetch devices for each site
            for site in networkSites {
                do {
                    let networkDevices = try await fetchNetworkDevices(consoleId: consoleId, siteId: site.id)
                    let ndCount = networkDevices.count
                    Self.logger.info("Network API: \(ndCount) devices in site \(site.name ?? site.id)")
                    for nd in networkDevices {
                        let mac = MACAddress(nd.macAddress)?.canonicalString ?? nd.macAddress.uppercased()
                        isAPByMAC[mac] = nd.isAccessPoint
                    }
                } catch {
                    let siteId = site.id
                    Self.logger.error("Failed to fetch devices for site \(siteId): \(error)")
                }
            }
        }

        // Enrich devices
        var enriched = devices
        for i in enriched.indices {
            enriched[i].isWirelessAP = isAPByMAC[enriched[i].mac]
        }

        let apCount = enriched.filter { $0.isWirelessAP == true }.count
        Self.logger.info("Network API enrichment: \(apCount) wireless APs identified out of \(enriched.count) devices")
        return enriched
    }

    // MARK: - Network API (via Cloud Connector)

    private func fetchNetworkSites(consoleId: String) async throws -> [UbiquitiNetworkSite] {
        guard let encodedConsoleId = consoleId.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://api.ui.com/v1/connector/consoles/\(encodedConsoleId)/proxy/network/integration/v1/sites") else {
            throw WiFiAPAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: UbiquitiNetworkSitesResponse = try await performRequest(request)
        return response.data
    }

    private func fetchNetworkDevices(consoleId: String, siteId: String) async throws -> [UbiquitiNetworkDevice] {
        // Cloud connector proxy: /v1/connector/consoles/{consoleId}/proxy/network/integration/v1/sites/{siteId}/devices
        // The consoleId contains a colon (e.g. "ABC123:456") — must be percent-encoded in the path
        guard let encodedConsoleId = consoleId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw WiFiAPAPIError.invalidResponse
        }
        var urlComponents = URLComponents(string: "https://api.ui.com/v1/connector/consoles/\(encodedConsoleId)/proxy/network/integration/v1/sites/\(siteId)/devices")!
        urlComponents.queryItems = [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = urlComponents.url else {
            throw WiFiAPAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: UbiquitiNetworkDevicesResponse = try await performRequest(request)
        return response.data
    }

    private func fetchDevicesPage(nextToken: String?) async throws -> UbiquitiDevicesResponse {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent("devices"), resolvingAgainstBaseURL: false)!

        if let token = nextToken {
            urlComponents.queryItems = [URLQueryItem(name: "nextToken", value: token)]
        }

        guard let url = urlComponents.url else {
            throw WiFiAPAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        guard let apiKey = credentials.apiKey else {
            throw WiFiAPAPIError.unauthorized
        }
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await performRequest(request)
    }

    private func performRequest<T: Decodable>(_ request: URLRequest, retryCount: Int = 0) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw WiFiAPAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WiFiAPAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw WiFiAPAPIError.unauthorized
        case 403:
            throw WiFiAPAPIError.forbidden
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            if retryCount < 3, let waitSeconds = retryAfter {
                Self.logger.info("Rate limited, waiting \(waitSeconds)s (retry \(retryCount + 1)/3)")
                try await Task.sleep(for: .seconds(waitSeconds))
                return try await performRequest(request, retryCount: retryCount + 1)
            }
            throw WiFiAPAPIError.rateLimited(retryAfter: retryAfter)
        default:
            let bodyStr = String(data: data, encoding: .utf8) ?? "(no body)"
            let statusCode = httpResponse.statusCode
            Self.logger.error("HTTP \(statusCode) response body: \(bodyStr)")
            throw WiFiAPAPIError.serverError(statusCode: statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("Failed to decode response: \(error.localizedDescription)")
            throw WiFiAPAPIError.invalidResponse
        }
    }
}
