@preconcurrency import Foundation
import os.log

// MARK: - Azure API Client

/// Azure API client for ARM (Azure Resource Manager) services
actor AzureAPIClient: CloudProviderAPIClient, VMCapableProvider, KubernetesCapableProvider {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AzureAPIClient")

    private var credentials: CloudCredentials
    private let accountID: UUID

    private nonisolated static let managementBaseURL = "https://management.azure.com"

    // API Versions (2025 latest)
    private nonisolated static let subscriptionAPIVersion = "2022-12-01"
    private nonisolated static let aksAPIVersion = "2025-09-01"
    private nonisolated static let aksCredentialsAPIVersion = "2025-02-01"
    private nonisolated static let vmAPIVersion = "2024-07-01"
    private nonisolated static let networkAPIVersion = "2024-01-01"


    init(credentials: CloudCredentials, accountID: UUID? = nil) {
        self.credentials = credentials
        self.accountID = accountID ?? credentials.accountID
    }

    // MARK: - CloudProviderAPIClient

    func validateCredentials() async throws -> Bool {
        guard let token = credentials.bearerToken,
              let subscriptionId = credentials.azureSubscriptionId else {
            throw CloudAPIError.invalidCredentials
        }

        // Try to get subscription info to validate the token
        let url = URL(string: "\(Self.managementBaseURL)/subscriptions/\(subscriptionId)?api-version=\(Self.subscriptionAPIVersion)")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        return httpResponse.statusCode == 200
    }

    func getAccountInfo() async throws -> ProviderAccountInfo {
        guard let subscriptionId = credentials.azureSubscriptionId else {
            throw CloudAPIError.invalidCredentials
        }

        return ProviderAccountInfo(
            accountID: subscriptionId,
            displayName: credentials.azureSubscriptionName ?? subscriptionId
        )
    }

    // MARK: - VMCapableProvider

    func listInstances() async throws -> [CloudInstance] {
        guard let token = try await ensureValidToken(),
              let subscriptionId = credentials.azureSubscriptionId else {
            Self.logger.error("Azure listInstances: Missing token or subscription ID")
            throw CloudAPIError.invalidCredentials
        }

        Self.logger.info("Azure listInstances: subscription=\(subscriptionId)")

        var instances: [CloudInstance] = []
        var nextLink: String? = nil

        repeat {
            let url: URL
            if let next = nextLink {
                url = URL(string: next)!
            } else {
                url = URL(string: "\(Self.managementBaseURL)/subscriptions/\(subscriptionId)/providers/Microsoft.Compute/virtualMachines?api-version=\(Self.vmAPIVersion)")!
            }

            let response: AzureVMListResponse = try await makeRequest(url: url, token: token)

            for vm in response.value {
                var instance = vm.toCloudInstance(accountID: accountID)
                // Try to get public IP for each VM
                if let nicId = vm.properties?.networkProfile?.networkInterfaces?.first?.id {
                    if let publicIP = try? await getVMPublicIP(nicId: nicId, token: token) {
                        instance.ipv4Address = publicIP
                    }
                }
                instances.append(instance)
            }

            nextLink = response.nextLink
        } while nextLink != nil

        return instances
    }

    /// Get the public IP address for a VM by looking up its network interface
    private func getVMPublicIP(nicId: String, token: String) async throws -> String? {
        // Get the network interface
        let nicURL = URL(string: "\(Self.managementBaseURL)\(nicId)?api-version=\(Self.networkAPIVersion)")!
        let nic: AzureNetworkInterface = try await makeRequest(url: nicURL, token: token)

        // Find public IP reference
        guard let publicIPRef = nic.properties?.ipConfigurations?.first?.properties?.publicIPAddress,
              let publicIPId = publicIPRef.id else {
            return nil
        }

        // Get the public IP address
        let publicIPURL = URL(string: "\(Self.managementBaseURL)\(publicIPId)?api-version=\(Self.networkAPIVersion)")!
        let publicIP: AzurePublicIPAddress = try await makeRequest(url: publicIPURL, token: token)

        return publicIP.properties?.ipAddress
    }

    // MARK: - KubernetesCapableProvider

    func listClusters() async throws -> [CloudKubernetesCluster] {
        guard let token = try await ensureValidToken(),
              let subscriptionId = credentials.azureSubscriptionId else {
            Self.logger.error("Azure listClusters: Missing token or subscription ID")
            throw CloudAPIError.invalidCredentials
        }

        Self.logger.info("Azure listClusters: subscription=\(subscriptionId)")

        var clusters: [CloudKubernetesCluster] = []
        var nextLink: String? = nil

        repeat {
            let url: URL
            if let next = nextLink {
                url = URL(string: next)!
            } else {
                url = URL(string: "\(Self.managementBaseURL)/subscriptions/\(subscriptionId)/providers/Microsoft.ContainerService/managedClusters?api-version=\(Self.aksAPIVersion)")!
            }

            let response: AKSClusterListResponse = try await makeRequest(url: url, token: token)

            for aksCluster in response.value {
                clusters.append(aksCluster.toCloudKubernetesCluster(accountID: accountID))
            }

            nextLink = response.nextLink
        } while nextLink != nil

        return clusters
    }

    func getKubeconfig(clusterID: String) async throws -> String {
        guard let token = try await ensureValidToken(),
              let subscriptionId = credentials.azureSubscriptionId else {
            throw CloudAPIError.invalidCredentials
        }

        // clusterID is the full ARM resource ID
        // Format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ContainerService/managedClusters/{name}

        // Parse resource group and cluster name from the resource ID
        let components = clusterID.components(separatedBy: "/")
        guard let rgIndex = components.firstIndex(of: "resourceGroups"),
              rgIndex + 1 < components.count,
              let nameIndex = components.firstIndex(of: "managedClusters"),
              nameIndex + 1 < components.count else {
            throw CloudAPIError.invalidResponse
        }

        let resourceGroup = components[rgIndex + 1]
        let clusterName = components[nameIndex + 1]

        // Call the listClusterUserCredential API
        let url = URL(string: "\(Self.managementBaseURL)/subscriptions/\(subscriptionId)/resourceGroups/\(resourceGroup)/providers/Microsoft.ContainerService/managedClusters/\(clusterName)/listClusterUserCredential?api-version=\(Self.aksCredentialsAPIVersion)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Empty body required for POST
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "Azure", code: -1))
        }

        try handleHTTPError(statusCode: httpResponse.statusCode, data: data)

        let credentialsResponse = try JSONDecoder().decode(AKSCredentialsResponse.self, from: data)

        // Decode the base64 kubeconfig
        guard let firstConfig = credentialsResponse.kubeconfigs.first,
              let kubeconfigData = Data(base64Encoded: firstConfig.value),
              let kubeconfig = String(data: kubeconfigData, encoding: .utf8) else {
            Self.logger.error("Failed to decode kubeconfig from Azure response")
            throw CloudAPIError.invalidResponse
        }

        return kubeconfig
    }

    // MARK: - Token Management

    /// Ensure we have a valid access token, refreshing if needed
    private func ensureValidToken() async throws -> String? {
        // Check if token needs refresh
        if credentials.needsRefresh {
            do {
                try await refreshCredentials()
            } catch {
                Self.logger.error("Failed to refresh Azure token: \(error.localizedDescription)")
                throw CloudAPIError.unauthorized
            }
        }

        return credentials.bearerToken
    }

    /// Refresh the Azure access token
    private func refreshCredentials() async throws {
        guard let refreshToken = credentials.azureRefreshToken,
              let tenantId = credentials.azureTenantId else {
            throw CloudAPIError.unauthorized
        }

        let flowManager = await AzureDeviceCodeFlowManager()
        let currentSession = AzureSession(
            accessToken: credentials.azureAccessToken ?? "",
            refreshToken: refreshToken,
            tokenExpiresAt: credentials.azureTokenExpiresAt ?? Date.distantPast,
            tenantId: tenantId
        )

        let newSession = try await flowManager.refreshToken(session: currentSession)

        // Update stored credentials
        credentials.azureAccessToken = newSession.accessToken
        credentials.azureRefreshToken = newSession.refreshToken
        credentials.azureTokenExpiresAt = newSession.tokenExpiresAt

        // Persist updated credentials - capture locally for MainActor
        let updatedCredentials = credentials
        try await MainActor.run {
            try CloudAccountManager.shared.updateCredentials(updatedCredentials)
        }
    }

    // MARK: - Request Helpers

    private func makeRequest<T: Decodable>(url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Self.logger.debug("Azure API request: \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "Azure", code: -1))
        }

        Self.logger.debug("Azure API response: HTTP \(httpResponse.statusCode)")

        try handleHTTPError(statusCode: httpResponse.statusCode, data: data, url: url)

        // Decode response
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logger.error("Failed to decode response: \(error.localizedDescription)")
            // Log raw response for debugging
            if let responseStr = String(data: data, encoding: .utf8) {
                Self.logger.error("Raw response: \(responseStr.prefix(500))")
            }
            throw CloudAPIError.decodingError(error)
        }
    }

    private func handleHTTPError(statusCode: Int, data: Data? = nil, url: URL? = nil) throws {
        switch statusCode {
        case 200..<300:
            return // Success
        case 401:
            throw CloudAPIError.unauthorized
        case 403:
            throw CloudAPIError.forbidden
        case 404:
            throw CloudAPIError.notFound
        case 429:
            throw CloudAPIError.rateLimited
        default:
            // Log all error responses for debugging
            if let data = data {
                if let errorResponse = try? JSONDecoder().decode(AzureAPIErrorResponse.self, from: data) {
                    Self.logger.error("Azure API error (HTTP \(statusCode)): \(errorResponse.error.code) - \(errorResponse.error.message)")
                } else if let rawBody = String(data: data, encoding: .utf8) {
                    Self.logger.error("Azure API error (HTTP \(statusCode)) raw response: \(rawBody.prefix(1000))")
                }
            }
            if let url = url {
                Self.logger.error("Failed URL: \(url.absoluteString)")
            }
            throw CloudAPIError.serverError(statusCode)
        }
    }
}
