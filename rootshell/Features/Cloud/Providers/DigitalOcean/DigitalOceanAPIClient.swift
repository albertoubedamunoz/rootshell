import Foundation
import os.log

// MARK: - DigitalOcean API Client

/// HTTP client for DigitalOcean API v2
actor DigitalOceanAPIClient: CloudProviderAPIClient, VMCapableProvider, KubernetesCapableProvider {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "DigitalOceanAPIClient")

    private let baseURL = URL(string: "https://api.digitalocean.com/v2")!
    private let credentials: CloudCredentials
    private let accountID: UUID
    private let urlSession: URLSession

    init(credentials: CloudCredentials, accountID: UUID) {
        self.credentials = credentials
        self.accountID = accountID
        self.urlSession = URLSession.shared
    }

    // MARK: - CloudProviderAPIClient

    func validateCredentials() async throws -> Bool {
        Self.logger.info("Validating DigitalOcean credentials")
        do {
            _ = try await getAccountInfo()
            Self.logger.info("DigitalOcean credentials validated successfully")
            return true
        } catch CloudAPIError.unauthorized {
            Self.logger.warning("DigitalOcean credentials validation failed - unauthorized")
            return false
        } catch {
            Self.logger.error("DigitalOcean credentials validation failed: \(error.localizedDescription)")
            throw error
        }
    }

    func getAccountInfo() async throws -> ProviderAccountInfo {
        Self.logger.info("Fetching DigitalOcean account info")
        let response: DigitalOceanAccountWrapper = try await get(path: "/account")
        return response.account.toProviderAccountInfo()
    }

    // MARK: - VMCapableProvider

    func listInstances() async throws -> [CloudInstance] {
        Self.logger.info("Fetching DigitalOcean droplets")
        var allDroplets: [DigitalOceanDropletResponse] = []
        var page = 1
        let perPage = 100

        // Paginate through all droplets
        while true {
            let response: DigitalOceanDropletsResponse = try await get(
                path: "/droplets",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: String(perPage))
                ]
            )

            allDroplets.append(contentsOf: response.droplets)

            // Check if there are more pages
            if response.droplets.count < perPage {
                break
            }
            page += 1
        }

        Self.logger.info("Fetched \(allDroplets.count) DigitalOcean droplets")
        return allDroplets.map { $0.toCloudInstance(accountID: accountID) }
    }

    // MARK: - KubernetesCapableProvider

    func listClusters() async throws -> [CloudKubernetesCluster] {
        Self.logger.info("Fetching DOKS clusters")
        var allClusters: [DigitalOceanKubernetesClusterResponse] = []
        var page = 1
        let perPage = 100

        // Paginate through all clusters
        while true {
            let response: DigitalOceanKubernetesClustersResponse = try await get(
                path: "/kubernetes/clusters",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: String(perPage))
                ]
            )

            allClusters.append(contentsOf: response.kubernetesClusters)

            // Check if there are more pages
            if response.kubernetesClusters.count < perPage {
                break
            }
            page += 1
        }

        Self.logger.info("Fetched \(allClusters.count) DOKS clusters")
        return allClusters.map { $0.toCloudKubernetesCluster(accountID: accountID) }
    }

    func getKubeconfig(clusterID: String) async throws -> String {
        Self.logger.info("Fetching kubeconfig for DOKS cluster \(clusterID)")

        // DigitalOcean returns raw YAML, not JSON
        let url = baseURL.appendingPathComponent("/kubernetes/clusters/\(clusterID)/kubeconfig")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        guard let token = credentials.bearerToken else {
            throw CloudAPIError.invalidCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Self.logger.debug("GET \(url.absoluteString)")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.invalidResponse
        }

        Self.logger.debug("Response status: \(httpResponse.statusCode)")

        // Handle error responses
        switch httpResponse.statusCode {
        case 200...299:
            break // Success
        case 401:
            throw CloudAPIError.unauthorized
        case 403:
            throw CloudAPIError.forbidden
        case 404:
            throw CloudAPIError.notFound
        case 429:
            throw CloudAPIError.rateLimited
        case 500...599:
            throw CloudAPIError.serverError(httpResponse.statusCode)
        default:
            throw CloudAPIError.serverError(httpResponse.statusCode)
        }

        // The response is raw YAML
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw CloudAPIError.invalidResponse
        }

        return yaml
    }

    // MARK: - HTTP Methods

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems

        guard let url = components.url else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let token = credentials.bearerToken else {
            throw CloudAPIError.invalidCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Self.logger.debug("GET \(url.absoluteString)")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.invalidResponse
        }

        Self.logger.debug("Response status: \(httpResponse.statusCode)")

        // Handle error responses
        switch httpResponse.statusCode {
        case 200...299:
            break // Success
        case 401:
            throw CloudAPIError.unauthorized
        case 403:
            throw CloudAPIError.forbidden
        case 404:
            throw CloudAPIError.notFound
        case 429:
            throw CloudAPIError.rateLimited
        case 500...599:
            throw CloudAPIError.serverError(httpResponse.statusCode)
        default:
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(DigitalOceanErrorResponse.self, from: data) {
                Self.logger.error("DigitalOcean API error: \(errorResponse.message)")
            }
            throw CloudAPIError.serverError(httpResponse.statusCode)
        }

        // Decode response
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logger.error("Failed to decode response: \(error.localizedDescription)")
            throw CloudAPIError.decodingError(error)
        }
    }
}
