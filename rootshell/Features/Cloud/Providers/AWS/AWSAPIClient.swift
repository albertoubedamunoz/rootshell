import Foundation
import os.log

// MARK: - AWS API Client

/// AWS API client for EC2 and EKS services
actor AWSAPIClient: CloudProviderAPIClient, VMCapableProvider, KubernetesCapableProvider {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AWSAPIClient")

    private let credentials: CloudCredentials
    private let accountID: UUID

    private nonisolated static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(credentials: CloudCredentials, accountID: UUID? = nil) {
        self.credentials = credentials
        self.accountID = accountID ?? credentials.accountID
    }

    // MARK: - CloudProviderAPIClient

    func validateCredentials() async throws -> Bool {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        // Call STS GetCallerIdentity to validate credentials
        let identity = try await getCallerIdentity(credentials: awsCreds)
        return identity.Account != nil
    }

    func getAccountInfo() async throws -> ProviderAccountInfo {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        let identity = try await getCallerIdentity(credentials: awsCreds)

        return ProviderAccountInfo(
            accountID: identity.Account,
            displayName: identity.Arn ?? identity.UserId
        )
    }

    // MARK: - VMCapableProvider

    func listInstances() async throws -> [CloudInstance] {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        var instances: [CloudInstance] = []
        var nextToken: String? = nil

        repeat {
            let response = try await describeInstances(credentials: awsCreds, nextToken: nextToken)

            if let reservations = response.Reservations {
                for reservation in reservations {
                    if let reservationInstances = reservation.Instances {
                        for ec2Instance in reservationInstances {
                            instances.append(ec2Instance.toCloudInstance(accountID: accountID))
                        }
                    }
                }
            }

            nextToken = response.NextToken
        } while nextToken != nil

        // Resolve AMI names for better OS detection
        let imageIDs = Set(instances.compactMap { $0.image })
        if !imageIDs.isEmpty {
            let imageNames = await resolveImageNames(credentials: awsCreds, imageIDs: Array(imageIDs))
            // Update instances with resolved image names
            for i in instances.indices {
                if let amiID = instances[i].image, let imageName = imageNames[amiID] {
                    instances[i].image = imageName
                }
            }
        }

        return instances
    }

    /// Resolve AMI IDs to human-readable image names
    private func resolveImageNames(credentials: AWSCredentials, imageIDs: [String]) async -> [String: String] {
        do {
            let response = try await describeImages(credentials: credentials, imageIDs: imageIDs)
            var mapping: [String: String] = [:]
            for image in response.images {
                // Prefer name, fall back to description
                if let name = image.name, !name.isEmpty {
                    mapping[image.imageId] = name
                } else if let desc = image.description, !desc.isEmpty {
                    mapping[image.imageId] = desc
                }
            }
            return mapping
        } catch {
            Self.logger.warning("Failed to resolve AMI names: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - KubernetesCapableProvider

    func listClusters() async throws -> [CloudKubernetesCluster] {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        var clusters: [CloudKubernetesCluster] = []
        var nextToken: String? = nil

        // First get all cluster names
        var clusterNames: [String] = []
        repeat {
            let response = try await listEKSClusters(credentials: awsCreds, nextToken: nextToken)
            if let names = response.clusters {
                clusterNames.append(contentsOf: names)
            }
            nextToken = response.nextToken
        } while nextToken != nil

        // Then describe each cluster to get full details
        for clusterName in clusterNames {
            do {
                let clusterResponse = try await describeEKSCluster(credentials: awsCreds, clusterName: clusterName)
                if let cluster = clusterResponse.cluster {
                    clusters.append(cluster.toCloudKubernetesCluster(accountID: accountID, region: awsCreds.region))
                }
            } catch {
                // Log error but continue with other clusters
                Self.logger.warning("Failed to describe EKS cluster \(clusterName): \(error.localizedDescription)")
            }
        }

        return clusters
    }

    func getKubeconfig(clusterID: String) async throws -> String {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        // clusterID is the cluster ARN or name
        let clusterName: String
        if clusterID.contains(":") {
            // It's an ARN, extract the cluster name
            clusterName = clusterID.components(separatedBy: "/").last ?? clusterID
        } else {
            clusterName = clusterID
        }

        // Get cluster details
        let clusterResponse = try await describeEKSCluster(credentials: awsCreds, clusterName: clusterName)
        guard let cluster = clusterResponse.cluster,
              let endpoint = cluster.endpoint,
              let caData = cluster.certificateAuthority?.data,
              let name = cluster.name else {
            throw CloudAPIError.invalidResponse
        }

        // Generate EKS token
        let token = try EKSTokenGenerator.generateToken(
            clusterName: name,
            region: awsCreds.region,
            credentials: awsCreds.signingCredentials
        )

        // Generate kubeconfig YAML
        let kubeconfig = EKSKubeconfigGenerator.generate(
            clusterName: name,
            clusterARN: cluster.arn ?? name,
            endpoint: endpoint,
            certificateAuthorityData: caData,
            token: token
        )

        return kubeconfig
    }

    // MARK: - STS API

    private func getCallerIdentity(credentials: AWSCredentials) async throws -> STSCallerIdentity {
        let endpoint = "https://sts.\(credentials.region).amazonaws.com"
        let queryString = "Action=GetCallerIdentity&Version=2011-06-15"

        guard let url = URL(string: "\(endpoint)/?\(queryString)") else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        AWSSignatureV4.sign(
            request: &request,
            credentials: credentials.signingCredentials,
            region: credentials.region,
            service: "sts"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        try handleHTTPError(statusCode: httpResponse.statusCode)

        // STS returns XML - parse it
        let xmlString = String(data: data, encoding: .utf8) ?? ""
        return try parseSTSCallerIdentityXML(xmlString)
    }

    /// Parse STS GetCallerIdentity XML response
    private func parseSTSCallerIdentityXML(_ xml: String) throws -> STSCallerIdentity {
        // Simple XML parsing for STS response
        // Format: <GetCallerIdentityResponse><GetCallerIdentityResult><Arn>...</Arn><UserId>...</UserId><Account>...</Account></GetCallerIdentityResult></GetCallerIdentityResponse>

        func extractValue(tag: String, from xml: String) -> String? {
            let pattern = "<\(tag)>([^<]*)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range(at: 1), in: xml) else {
                return nil
            }
            return String(xml[range])
        }

        let arn = extractValue(tag: "Arn", from: xml)
        let userId = extractValue(tag: "UserId", from: xml)
        let account = extractValue(tag: "Account", from: xml)

        guard account != nil else {
            throw CloudAPIError.invalidResponse
        }

        return STSCallerIdentity(Arn: arn, UserId: userId, Account: account)
    }

    // MARK: - EC2 API

    private func describeInstances(credentials: AWSCredentials, nextToken: String? = nil) async throws -> EC2DescribeInstancesResponse {
        let endpoint = "https://ec2.\(credentials.region).amazonaws.com"
        var queryItems = "Action=DescribeInstances&Version=2016-11-15"

        if let token = nextToken {
            queryItems += "&NextToken=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
        }

        guard let url = URL(string: "\(endpoint)/?\(queryItems)") else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        AWSSignatureV4.sign(
            request: &request,
            credentials: credentials.signingCredentials,
            region: credentials.region,
            service: "ec2"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        try handleHTTPError(statusCode: httpResponse.statusCode)

        // EC2 Query API returns XML, parse it
        let xmlString = String(data: data, encoding: .utf8) ?? ""

        // Debug: print full response
        Self.logger.debug("EC2 DescribeInstances XML response: \(xmlString)")

        return parseEC2DescribeInstancesXML(xmlString)
    }

    /// Parse EC2 DescribeInstances XML response
    private func parseEC2DescribeInstancesXML(_ xml: String) -> EC2DescribeInstancesResponse {
        // For empty reservation set, return empty response
        if xml.contains("<reservationSet/>") || xml.contains("<reservationSet></reservationSet>") {
            return EC2DescribeInstancesResponse(Reservations: [], NextToken: nil)
        }

        // Parse instances from XML using XMLParser
        let parser = EC2DescribeInstancesXMLParser(xml: xml)
        let response = parser.parse()

        // Debug: print parsed results
        let reservationCount = response.Reservations?.count ?? 0
        let instanceCount = response.Reservations?.reduce(0) { $0 + ($1.Instances?.count ?? 0) } ?? 0
        Self.logger.debug("Parsed \(reservationCount) reservations with \(instanceCount) instances")

        return response
    }

    /// Call EC2 DescribeImages to get AMI details
    private func describeImages(credentials: AWSCredentials, imageIDs: [String]) async throws -> EC2DescribeImagesResponse {
        let endpoint = "https://ec2.\(credentials.region).amazonaws.com"
        var queryItems = "Action=DescribeImages&Version=2016-11-15"

        // Add image IDs as query parameters
        for (index, imageID) in imageIDs.enumerated() {
            let encodedID = imageID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? imageID
            queryItems += "&ImageId.\(index + 1)=\(encodedID)"
        }

        guard let url = URL(string: "\(endpoint)/?\(queryItems)") else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        AWSSignatureV4.sign(
            request: &request,
            credentials: credentials.signingCredentials,
            region: credentials.region,
            service: "ec2"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        try handleHTTPError(statusCode: httpResponse.statusCode)

        let xmlString = String(data: data, encoding: .utf8) ?? ""
        let parser = EC2DescribeImagesXMLParser(xml: xmlString)
        return parser.parse()
    }

    // MARK: - EKS API

    private func listEKSClusters(credentials: AWSCredentials, nextToken: String? = nil) async throws -> EKSListClustersResponse {
        let endpoint = "https://eks.\(credentials.region).amazonaws.com"
        var path = "/clusters"

        if let token = nextToken {
            path += "?nextToken=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
        }

        guard let url = URL(string: "\(endpoint)\(path)") else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        AWSSignatureV4.sign(
            request: &request,
            credentials: credentials.signingCredentials,
            region: credentials.region,
            service: "eks"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        try handleHTTPError(statusCode: httpResponse.statusCode)

        return try Self.jsonDecoder.decode(EKSListClustersResponse.self, from: data)
    }

    private func describeEKSCluster(credentials: AWSCredentials, clusterName: String) async throws -> EKSDescribeClusterResponse {
        let endpoint = "https://eks.\(credentials.region).amazonaws.com"
        let encodedName = clusterName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clusterName
        let path = "/clusters/\(encodedName)"

        guard let url = URL(string: "\(endpoint)\(path)") else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        AWSSignatureV4.sign(
            request: &request,
            credentials: credentials.signingCredentials,
            region: credentials.region,
            service: "eks"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        try handleHTTPError(statusCode: httpResponse.statusCode)

        return try Self.jsonDecoder.decode(EKSDescribeClusterResponse.self, from: data)
    }

    // MARK: - EC2 Instance Connect (Serial Console)

    /// Send SSH public key for EC2 Serial Console access.
    /// The key is only valid for 60 seconds after this call succeeds.
    /// If serial console is not enabled for the account, this will automatically enable it and retry.
    /// - Parameters:
    ///   - instanceId: The EC2 instance ID (e.g., "i-0123456789abcdef0")
    ///   - region: AWS region (uses account default if nil)
    ///   - serialPort: Serial port number (0 for most instances)
    ///   - sshPublicKey: The SSH public key in OpenSSH format (e.g., "ssh-ed25519 AAAA...")
    /// - Returns: Request ID if successful
    func sendSerialConsoleSSHPublicKey(
        instanceId: String,
        region: String? = nil,
        serialPort: Int = 0,
        sshPublicKey: String
    ) async throws -> String {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        let targetRegion = region ?? awsCreds.region

        // Try to send the key, auto-enabling serial console if needed
        return try await sendSerialConsoleSSHPublicKeyInternal(
            instanceId: instanceId,
            region: targetRegion,
            serialPort: serialPort,
            sshPublicKey: sshPublicKey,
            credentials: awsCreds,
            autoEnableAttempted: false
        )
    }

    /// Internal implementation with auto-enable retry logic
    private func sendSerialConsoleSSHPublicKeyInternal(
        instanceId: String,
        region: String,
        serialPort: Int,
        sshPublicKey: String,
        credentials awsCreds: AWSCredentials,
        autoEnableAttempted: Bool
    ) async throws -> String {
        // EC2 Instance Connect is a separate service from EC2
        let endpoint = "https://ec2-instance-connect.\(region).amazonaws.com"

        // JSON body for the API call
        let requestBody: [String: Any] = [
            "InstanceId": instanceId,
            "SerialPort": serialPort,
            "SSHPublicKey": sshPublicKey
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        guard let url = URL(string: endpoint) else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // X-Amz-Target header specifies the action
        // Note: AWS uses uppercase "AWSEC2" prefix, not "AwsEc2"
        request.setValue(
            "AWSEC2InstanceConnectService.SendSerialConsoleSSHPublicKey",
            forHTTPHeaderField: "X-Amz-Target"
        )

        AWSSignatureV4.sign(
            request: &request,
            credentials: awsCreds.signingCredentials,
            region: region,
            service: "ec2-instance-connect"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        // Debug: log the response
        let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 data>"
        let statusCode = httpResponse.statusCode
        Self.logger.debug("SendSerialConsoleSSHPublicKey response (HTTP \(statusCode)): \(responseBody)")

        // Check for HTTP errors, but try to extract AWS error message first
        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            // Try to parse AWS error format: {"__type": "...", "message": "..."}
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let awsType = errorJson["__type"] as? String ?? "Unknown"
                let awsMessage = errorJson["message"] as? String ?? errorJson["Message"] as? String ?? responseBody
                Self.logger.error("AWS Error: \(awsType) - \(awsMessage)")

                // Auto-enable serial console if not already attempted
                if awsType.contains("SerialConsoleAccessDisabled") && !autoEnableAttempted {
                    Self.logger.info("Serial console not enabled, attempting to enable it automatically...")
                    do {
                        try await enableSerialConsoleAccess(region: region)
                        Self.logger.info("Serial console enabled successfully, retrying key upload...")
                        // Retry with the same key
                        return try await sendSerialConsoleSSHPublicKeyInternal(
                            instanceId: instanceId,
                            region: region,
                            serialPort: serialPort,
                            sshPublicKey: sshPublicKey,
                            credentials: awsCreds,
                            autoEnableAttempted: true
                        )
                    } catch {
                        Self.logger.error("Failed to auto-enable serial console: \(error.localizedDescription)")
                        throw CloudAPIError.forbidden  // Maps to .serialConsoleNotEnabled
                    }
                }

                // Map specific AWS errors to appropriate CloudAPIError types
                if awsType.contains("SerialConsoleAccessDisabled") {
                    throw CloudAPIError.forbidden  // Maps to .serialConsoleNotEnabled
                } else if awsType.contains("SerialConsoleSessionLimitExceeded") {
                    throw CloudAPIError.rateLimited  // Maps to .sessionLimitExceeded
                } else if awsType.contains("UnauthorizedAccess") || awsType.contains("AccessDenied") {
                    throw CloudAPIError.forbidden
                } else if awsType.contains("InvalidInstanceID") || awsType.contains("InstanceNotFound") {
                    throw CloudAPIError.notFound
                }

                throw CloudAPIError.serverError(httpResponse.statusCode)
            }
            try handleHTTPError(statusCode: httpResponse.statusCode)
        }

        // Parse response to check for success and get RequestId
        // Response format: {"RequestId": "...", "Success": true}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let success = json["Success"] as? Bool, !success {
                // Extract error message if available
                _ = json["Message"] as? String ?? "API returned Success: false"
                throw CloudAPIError.serverError(-1)
            }
            return json["RequestId"] as? String ?? ""
        }

        return ""
    }

    /// Enable EC2 Serial Console access for the account.
    /// This is a one-time operation per account/region.
    func enableSerialConsoleAccess(region: String? = nil) async throws {
        guard let awsCreds = credentials.awsCredentials else {
            throw CloudAPIError.invalidCredentials
        }

        let targetRegion = region ?? awsCreds.region
        let endpoint = "https://ec2.\(targetRegion).amazonaws.com"
        let queryString = "Action=EnableSerialConsoleAccess&Version=2016-11-15"

        guard let url = URL(string: "\(endpoint)/?\(queryString)") else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        AWSSignatureV4.sign(
            request: &request,
            credentials: awsCreds.signingCredentials,
            region: targetRegion,
            service: "ec2"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError(NSError(domain: "AWS", code: -1))
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""
        let statusCode = httpResponse.statusCode
        Self.logger.info("EnableSerialConsoleAccess response (HTTP \(statusCode)): \(responseBody)")

        try handleHTTPError(statusCode: httpResponse.statusCode)
    }

    // MARK: - Error Handling

    private func handleHTTPError(statusCode: Int) throws {
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
        case 500..<600:
            throw CloudAPIError.serverError(statusCode)
        default:
            throw CloudAPIError.serverError(statusCode)
        }
    }
}
