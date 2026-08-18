import Foundation
import os.log

// MARK: - Linode API Client

/// HTTP client for Linode API v4
@MainActor
final class LinodeAPIClient: CloudProviderAPIClient, VMCapableProvider, KubernetesCapableProvider {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LinodeAPIClient")

    private let baseURL = URL(string: "https://api.linode.com/v4")!
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
        Self.logger.info("Validating Linode credentials")
        do {
            _ = try await getAccountInfo()
            Self.logger.info("Linode credentials validated successfully")
            return true
        } catch CloudAPIError.unauthorized {
            Self.logger.warning("Linode credentials validation failed - unauthorized")
            return false
        } catch {
            Self.logger.error("Linode credentials validation failed: \(error.localizedDescription)")
            throw error
        }
    }

    func getAccountInfo() async throws -> ProviderAccountInfo {
        Self.logger.info("Fetching Linode account info")
        let response: LinodeAccountResponse = try await get(path: "/account")
        return response.toProviderAccountInfo()
    }

    // MARK: - VMCapableProvider

    func listInstances() async throws -> [CloudInstance] {
        Self.logger.info("Fetching Linode instances (all pages)")
        let instances: [LinodeInstanceResponse] = try await getAllPages(path: "/linode/instances")
        Self.logger.info("Fetched \(instances.count) Linode instances")
        return instances.map { $0.toCloudInstance(accountID: accountID) }
    }

    // MARK: - KubernetesCapableProvider

    func listClusters() async throws -> [CloudKubernetesCluster] {
        Self.logger.info("Fetching LKE clusters (all pages)")
        let clusterResponses: [LinodeLKEClusterResponse] = try await getAllPages(path: "/lke/clusters")
        Self.logger.info("Fetched \(clusterResponses.count) LKE clusters")

        // Fetch node counts for each cluster
        var clusters = clusterResponses.map { $0.toCloudKubernetesCluster(accountID: accountID) }

        for i in 0..<clusters.count {
            do {
                let nodeCount = try await fetchNodeCount(clusterID: clusters[i].providerClusterID)
                clusters[i].nodeCount = nodeCount
            } catch {
                Self.logger.warning("Failed to fetch node count for cluster \(clusters[i].label): \(error.localizedDescription)")
            }

            // Also fetch API endpoints
            do {
                let endpoint = try await fetchAPIEndpoint(clusterID: clusters[i].providerClusterID)
                clusters[i].apiEndpoint = endpoint
            } catch {
                Self.logger.warning("Failed to fetch API endpoint for cluster \(clusters[i].label): \(error.localizedDescription)")
            }
        }

        return clusters
    }

    func getKubeconfig(clusterID: String) async throws -> String {
        Self.logger.info("Fetching kubeconfig for LKE cluster \(clusterID)")
        let response: LinodeLKEKubeconfigResponse = try await get(path: "/lke/clusters/\(clusterID)/kubeconfig")

        // The kubeconfig is base64 encoded
        guard let data = Data(base64Encoded: response.kubeconfig),
              let yaml = String(data: data, encoding: .utf8) else {
            throw CloudAPIError.invalidResponse
        }

        return yaml
    }

    // MARK: - LISH (Console)

    /// Get LISH access tokens for console access to a Linode instance
    /// Returns WebSocket URLs and authentication protocols for terminal/VNC access
    func getLishToken(instanceID: String) async throws -> LinodeLishData {
        Self.logger.info("Fetching LISH token for instance \(instanceID)")
        return try await post(path: "/linode/instances/\(instanceID)/lish")
    }

    // MARK: - Private Helpers

    private func fetchNodeCount(clusterID: String) async throws -> Int {
        let pools: [LinodeLKENodePoolResponse] = try await getAllPages(path: "/lke/clusters/\(clusterID)/pools")
        return pools.reduce(0) { $0 + $1.count }
    }

    private func fetchAPIEndpoint(clusterID: String) async throws -> String? {
        let endpoints: [LinodeLKEAPIEndpointResponse] = try await getAllPages(path: "/lke/clusters/\(clusterID)/api-endpoints")
        return endpoints.first?.endpoint
    }

    // MARK: - HTTP Methods

    /// Fetch all pages of a paginated Linode API endpoint
    private func getAllPages<T: Codable>(path: String) async throws -> [T] {
        var allItems: [T] = []
        var currentPage = 1

        while true {
            let separator = path.contains("?") ? "&" : "?"
            let paginatedPath = "\(path)\(separator)page=\(currentPage)"

            let response: LinodeListResponse<T> = try await get(path: paginatedPath)
            allItems.append(contentsOf: response.data)

            Self.logger.debug("Fetched page \(currentPage)/\(response.pages) (\(response.data.count) items, \(allItems.count)/\(response.results) total)")

            if currentPage >= response.pages {
                break
            }
            currentPage += 1
        }

        return allItems
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + path) else {
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
            if let errorResponse = try? JSONDecoder().decode(LinodeErrorResponse.self, from: data),
               let firstError = errorResponse.errors.first {
                Self.logger.error("Linode API error: \(firstError.reason)")
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

    private func post<T: Decodable>(path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw CloudAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let token = credentials.bearerToken else {
            throw CloudAPIError.invalidCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body = body {
            request.httpBody = body
        }

        Self.logger.debug("POST \(url.absoluteString)")

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
