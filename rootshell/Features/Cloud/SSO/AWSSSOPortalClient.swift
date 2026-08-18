import Foundation

// MARK: - AWS SSO Portal Client

/// AWS SSO Portal API client for listing accounts/roles and getting credentials
actor AWSSSOPortalClient {
    private let region: String
    private let accessToken: String
    private let baseURL: String

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(region: String, accessToken: String) {
        self.region = region
        self.accessToken = accessToken
        self.baseURL = "https://portal.sso.\(region).amazonaws.com"
    }

    // MARK: - List Accounts

    /// List AWS accounts available to the authenticated user
    func listAccounts() async throws -> [AWSSSOAccount] {
        var accounts: [AWSSSOAccount] = []
        var nextToken: String? = nil

        repeat {
            let response = try await fetchAccounts(nextToken: nextToken)
            if let accountList = response.accountList {
                accounts.append(contentsOf: accountList.map { $0.toAWSSSOAccount() })
            }
            nextToken = response.nextToken
        } while nextToken != nil

        return accounts
    }

    private func fetchAccounts(nextToken: String? = nil) async throws -> SSOListAccountsResponse {
        var urlString = "\(baseURL)/assignment/accounts"
        if let token = nextToken {
            urlString += "?next_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
        }

        guard let url = URL(string: urlString) else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AWSSSOError.accessDenied
        }

        if httpResponse.statusCode != 200 {
            throw AWSSSOError.apiError(code: "http_\(httpResponse.statusCode)", message: "Failed to list accounts")
        }

        return try jsonDecoder.decode(SSOListAccountsResponse.self, from: data)
    }

    // MARK: - List Account Roles

    /// List IAM roles available for a specific AWS account
    func listAccountRoles(accountId: String) async throws -> [AWSSSORole] {
        var roles: [AWSSSORole] = []
        var nextToken: String? = nil

        repeat {
            let response = try await fetchAccountRoles(accountId: accountId, nextToken: nextToken)
            if let roleList = response.roleList {
                roles.append(contentsOf: roleList.map { $0.toAWSSSORole() })
            }
            nextToken = response.nextToken
        } while nextToken != nil

        return roles
    }

    private func fetchAccountRoles(accountId: String, nextToken: String? = nil) async throws -> SSOListAccountRolesResponse {
        var urlString = "\(baseURL)/assignment/roles?account_id=\(accountId)"
        if let token = nextToken {
            urlString += "&next_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
        }

        guard let url = URL(string: urlString) else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AWSSSOError.accessDenied
        }

        if httpResponse.statusCode != 200 {
            throw AWSSSOError.apiError(code: "http_\(httpResponse.statusCode)", message: "Failed to list roles")
        }

        return try jsonDecoder.decode(SSOListAccountRolesResponse.self, from: data)
    }

    // MARK: - Get Role Credentials

    /// Get temporary AWS credentials for a specific role
    func getRoleCredentials(accountId: String, roleName: String) async throws -> AWSSTSCredentials {
        let encodedRole = roleName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? roleName
        let urlString = "\(baseURL)/federation/credentials?account_id=\(accountId)&role_name=\(encodedRole)"

        guard let url = URL(string: urlString) else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AWSSSOError.accessDenied
        }

        if httpResponse.statusCode != 200 {
            throw AWSSSOError.apiError(code: "http_\(httpResponse.statusCode)", message: "Failed to get role credentials")
        }

        let credentialsResponse = try jsonDecoder.decode(SSOGetRoleCredentialsResponse.self, from: data)
        return credentialsResponse.roleCredentials.toAWSSTSCredentials()
    }
}
