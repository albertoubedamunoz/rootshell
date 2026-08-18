import Foundation

// MARK: - EKS Token Generator

/// Generates EKS authentication tokens using AWS STS presigned URLs
/// Token format: k8s-aws-v1.<base64url-encoded-presigned-url>
struct EKSTokenGenerator {

    /// Token prefix as required by EKS
    private nonisolated static let tokenPrefix = "k8s-aws-v1."

    /// Token expiration in seconds (60 seconds for the presigned URL)
    private nonisolated static let tokenExpirationSeconds = 60

    /// Generate an EKS authentication token
    /// - Parameters:
    ///   - clusterName: The EKS cluster name
    ///   - region: AWS region
    ///   - credentials: AWS credentials for signing
    /// - Returns: The EKS token string
    nonisolated static func generateToken(
        clusterName: String,
        region: String,
        credentials: AWSSignatureV4.Credentials
    ) throws -> String {
        // Build the STS GetCallerIdentity presigned URL
        let stsEndpoint = "https://sts.\(region).amazonaws.com"
        let queryString = "Action=GetCallerIdentity&Version=2011-06-15"

        guard let baseURL = URL(string: "\(stsEndpoint)/?\(queryString)") else {
            throw EKSTokenError.invalidURL
        }

        // Headers to include in signing
        // The x-k8s-aws-id header is required for EKS to identify the cluster
        let headers = [
            "x-k8s-aws-id": clusterName
        ]

        // Create presigned URL
        guard let presignedURL = AWSSignatureV4.presignURL(
            url: baseURL,
            method: "GET",
            credentials: credentials,
            region: region,
            service: "sts",
            headers: headers,
            expiresIn: tokenExpirationSeconds
        ) else {
            throw EKSTokenError.signingFailed
        }

        // Encode the presigned URL to base64url
        guard let urlData = presignedURL.absoluteString.data(using: .utf8) else {
            throw EKSTokenError.encodingFailed
        }

        let encodedURL = urlData.base64URLEncodedString()

        // Return the token with prefix
        return tokenPrefix + encodedURL
    }
}

// MARK: - EKS Token Error

enum EKSTokenError: LocalizedError {
    case invalidURL
    case signingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to build STS URL"
        case .signingFailed:
            return "Failed to sign token request"
        case .encodingFailed:
            return "Failed to encode token"
        }
    }
}
