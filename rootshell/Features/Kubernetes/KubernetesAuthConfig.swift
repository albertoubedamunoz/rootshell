//
//  KubernetesAuthConfig.swift
//  rootshell
//
//  Authentication configuration extraction from kubeconfig for URLSession WebSocket
//

import Foundation
import Security
import os.log
import SwiftkubeClient
import Crypto

/// Authentication configuration extracted from kubeconfig for URLSession
/// Marked @unchecked Sendable because Security framework types (SecIdentity, SecCertificate)
/// are not marked Sendable but are thread-safe in practice
nonisolated struct KubernetesAuthConfig: @unchecked Sendable {
    /// The Kubernetes API server URL
    let serverURL: URL

    /// Bearer token for authentication (most common for cloud providers)
    let bearerToken: String?

    /// Client certificate identity for mTLS (self-managed clusters)
    let clientIdentity: SecIdentity?

    /// CA certificate for server validation
    let caCertificates: [SecCertificate]

    /// Whether to skip TLS verification (insecure)
    let skipTLSVerify: Bool

    /// The authentication method being used
    var authMethod: AuthMethod {
        if bearerToken != nil {
            return .bearerToken
        } else if clientIdentity != nil {
            return .clientCertificate
        } else {
            return .none
        }
    }

    enum AuthMethod: String, Sendable {
        case bearerToken = "Bearer Token"
        case clientCertificate = "Client Certificate"
        case none = "None"

        var displayName: String {
            switch self {
            case .bearerToken: return String(localized: "Bearer Token", comment: "Kubernetes auth method: bearer token")
            case .clientCertificate: return String(localized: "Client Certificate", comment: "Kubernetes auth method: client certificate")
            case .none: return String(localized: "None", comment: "Kubernetes auth method: no authentication")
            }
        }
    }

    /// Create auth config from a KubeConfig and context name
    /// - Parameters:
    ///   - kubeConfig: The parsed KubeConfig
    ///   - contextName: The context to use
    /// - Throws: KubernetesNodeShellError if auth extraction fails
    static func from(kubeConfig: KubeConfig, contextName: String) throws -> KubernetesAuthConfig {
        // Find the context
        guard let namedContext = kubeConfig.contexts?.first(where: { $0.name == contextName }) else {
            throw KubernetesNodeShellError.kubeconfigParseError("Context '\(contextName)' not found")
        }

        let context = namedContext.context

        // Find the cluster
        guard let namedCluster = kubeConfig.clusters?.first(where: { $0.name == context.cluster }) else {
            throw KubernetesNodeShellError.kubeconfigParseError("Cluster '\(context.cluster)' not found")
        }

        let cluster = namedCluster.cluster

        // Find the user
        guard let namedUser = kubeConfig.users?.first(where: { $0.name == context.user }) else {
            throw KubernetesNodeShellError.kubeconfigParseError("User '\(context.user)' not found")
        }

        let authInfo = namedUser.authInfo

        // Parse server URL
        guard let serverURL = URL(string: cluster.server) else {
            throw KubernetesNodeShellError.kubeconfigParseError("Invalid server URL: \(cluster.server)")
        }

        // Extract authentication
        var bearerToken: String? = nil
        var clientIdentity: SecIdentity? = nil

        // Try bearer token first
        if let token = authInfo.token {
            bearerToken = token
        }

        // Try client certificate if no token
        if bearerToken == nil {
            if let certData = authInfo.clientCertificateData,
               let keyData = authInfo.clientKeyData {
                clientIdentity = try createIdentity(certificateData: certData, keyData: keyData)
            }
        }

        // Check for unsupported auth methods
        if bearerToken == nil && clientIdentity == nil {
            // Check if using exec credential plugin (not supported on iOS)
            if authInfo.exec != nil {
                throw KubernetesNodeShellError.unsupportedAuthMethod(
                    "exec credential plugin (e.g., aws-iam-authenticator, gcloud)"
                )
            }

            // Check for token file (not supported - would need file access)
            if authInfo.tokenFile != nil {
                throw KubernetesNodeShellError.unsupportedAuthMethod(
                    "token file reference"
                )
            }

            // Check for cert/key file references (not supported - would need file access)
            if authInfo.clientCertificate != nil || authInfo.clientKey != nil {
                throw KubernetesNodeShellError.unsupportedAuthMethod(
                    "certificate/key file references (use embedded data instead)"
                )
            }
        }

        // Extract CA certificates
        var caCertificates: [SecCertificate] = []
        if let caData = cluster.certificateAuthorityData {
            if let caCert = createCertificate(from: caData) {
                caCertificates.append(caCert)
            }
        }

        let skipTLSVerify = cluster.insecureSkipTLSVerify ?? false

        return KubernetesAuthConfig(
            serverURL: serverURL,
            bearerToken: bearerToken,
            clientIdentity: clientIdentity,
            caCertificates: caCertificates,
            skipTLSVerify: skipTLSVerify
        )
    }

    /// Create a SecIdentity from PEM-encoded certificate and key data
    ///
    /// iOS doesn't automatically link separately-added certificates and keys into a SecIdentity.
    /// We use swift-crypto to parse EC keys and add them to the keychain with matching public key
    /// hashes so iOS can create an identity.
    private static func createIdentity(certificateData: Data, keyData: Data) throws -> SecIdentity? {
        // 1. Parse certificate PEM to DER
        guard let certDER = pemToDER(pemData: certificateData, type: "CERTIFICATE") else {
            throw KubernetesNodeShellError.kubeconfigParseError("Invalid client certificate format")
        }

        // Create SecCertificate
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw KubernetesNodeShellError.kubeconfigParseError("Failed to parse client certificate")
        }

        // 2. Parse private key - detect type from PEM header
        guard let keyPEM = String(data: keyData, encoding: .utf8) else {
            throw KubernetesNodeShellError.kubeconfigParseError("Invalid key encoding")
        }

        // 3. Parse key and create identity based on key type
        if keyPEM.contains("BEGIN EC PRIVATE KEY") || keyPEM.contains("BEGIN PRIVATE KEY") {
            // EC key (SEC1 or PKCS#8 format) - use swift-crypto
            return try createIdentityWithECKey(certificate: certificate, keyPEM: keyPEM)
        } else if keyPEM.contains("BEGIN RSA PRIVATE KEY") {
            // RSA key - use Security framework directly
            return try createIdentityWithRSAKey(certificate: certificate, keyData: keyData)
        } else {
            throw KubernetesNodeShellError.kubeconfigParseError("Unsupported private key format")
        }
    }

    /// Create SecIdentity with EC key using swift-crypto for parsing
    private static func createIdentityWithECKey(certificate: SecCertificate, keyPEM: String) throws -> SecIdentity? {
        // Try P-256 first (most common for Talos/k8s)
        if let identity = try? createIdentityWithP256Key(certificate: certificate, keyPEM: keyPEM) {
            return identity
        }
        // Try P-384
        if let identity = try? createIdentityWithP384Key(certificate: certificate, keyPEM: keyPEM) {
            return identity
        }
        // Try P-521
        if let identity = try? createIdentityWithP521Key(certificate: certificate, keyPEM: keyPEM) {
            return identity
        }
        throw KubernetesNodeShellError.kubeconfigParseError("Failed to parse EC key - unsupported curve")
    }

    private static func createIdentityWithP256Key(certificate: SecCertificate, keyPEM: String) throws -> SecIdentity? {
        let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        return try addKeyAndCertToKeychain(
            certificate: certificate,
            keyData: Data(key.x963Representation),
            keyType: kSecAttrKeyTypeECSECPrimeRandom,
            keySizeInBits: 256
        )
    }

    private static func createIdentityWithP384Key(certificate: SecCertificate, keyPEM: String) throws -> SecIdentity? {
        let key = try P384.Signing.PrivateKey(pemRepresentation: keyPEM)
        return try addKeyAndCertToKeychain(
            certificate: certificate,
            keyData: Data(key.x963Representation),
            keyType: kSecAttrKeyTypeECSECPrimeRandom,
            keySizeInBits: 384
        )
    }

    private static func createIdentityWithP521Key(certificate: SecCertificate, keyPEM: String) throws -> SecIdentity? {
        let key = try P521.Signing.PrivateKey(pemRepresentation: keyPEM)
        return try addKeyAndCertToKeychain(
            certificate: certificate,
            keyData: Data(key.x963Representation),
            keyType: kSecAttrKeyTypeECSECPrimeRandom,
            keySizeInBits: 521
        )
    }

    /// Create SecIdentity with RSA key
    private static func createIdentityWithRSAKey(certificate: SecCertificate, keyData: Data) throws -> SecIdentity? {
        guard let keyDER = pemToDER(pemData: keyData, type: "RSA PRIVATE KEY") ??
                          pemToDER(pemData: keyData, type: "PRIVATE KEY") else {
            throw KubernetesNodeShellError.kubeconfigParseError("Invalid RSA key format")
        }

        return try addKeyAndCertToKeychain(
            certificate: certificate,
            keyData: keyDER,
            keyType: kSecAttrKeyTypeRSA,
            keySizeInBits: 0  // Security framework will determine
        )
    }

    /// Add certificate and key to keychain, returning the created identity
    private static func addKeyAndCertToKeychain(
        certificate: SecCertificate,
        keyData: Data,
        keyType: CFString,
        keySizeInBits: Int
    ) throws -> SecIdentity? {
        // Create SecKey from key data
        var keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        if keySizeInBits > 0 {
            keyAttributes[kSecAttrKeySizeInBits as String] = keySizeInBits
        }

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, &error) else {
            throw KubernetesNodeShellError.kubeconfigParseError(
                "Failed to create SecKey: \(error?.takeRetainedValue().localizedDescription ?? "unknown")"
            )
        }

        // Use a unique tag for this key
        let tag = "com.rootshell.k8s.client.\(UUID().uuidString)"
        let tagData = tag.data(using: .utf8)!

        // Delete any existing items with this tag first
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData
        ] as CFDictionary)

        // Add the private key to keychain
        let keyAddQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnPersistentRef as String: true,
        ]

        var keyPersistentRef: CFTypeRef?
        var status = SecItemAdd(keyAddQuery as CFDictionary, &keyPersistentRef)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KubernetesNodeShellError.kubeconfigParseError("Failed to add key to keychain: \(status)")
        }

        // Add the certificate to keychain
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        status = SecItemAdd(certAddQuery as CFDictionary, nil)
        // Allow duplicate - the cert might already exist
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            // Clean up key
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tagData] as CFDictionary)
            throw KubernetesNodeShellError.kubeconfigParseError("Failed to add cert to keychain: \(status)")
        }

        // Query for identity - iOS links cert and key by matching public key hash
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var identityRefs: CFTypeRef?
        status = SecItemCopyMatching(identityQuery as CFDictionary, &identityRefs)

        if status == errSecSuccess, let identities = identityRefs as? [SecIdentity] {
            // Find the identity that matches our certificate
            for identity in identities {
                var certRef: SecCertificate?
                if SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
                   let foundCert = certRef {
                    // Compare certificate data
                    let foundCertData = SecCertificateCopyData(foundCert) as Data
                    let ourCertData = SecCertificateCopyData(certificate) as Data
                    if foundCertData == ourCertData {
                        return identity
                    }
                }
            }
        }

        // Clean up if we couldn't find/create identity
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tagData] as CFDictionary)

        throw KubernetesNodeShellError.kubeconfigParseError(
            "Failed to create identity - certificate and key public keys may not match"
        )
    }

    /// Create a SecCertificate from PEM or DER data
    private static func createCertificate(from data: Data) -> SecCertificate? {
        // Try as DER first
        if let cert = SecCertificateCreateWithData(nil, data as CFData) {
            return cert
        }

        // Try as PEM
        if let derData = pemToDER(pemData: data, type: "CERTIFICATE") {
            return SecCertificateCreateWithData(nil, derData as CFData)
        }

        return nil
    }

    /// Convert PEM-encoded data to DER format
    private static func pemToDER(pemData: Data, type: String) -> Data? {
        guard let pemString = String(data: pemData, encoding: .utf8) else {
            return nil
        }

        // Remove header and footer
        let beginMarker = "-----BEGIN \(type)-----"
        let endMarker = "-----END \(type)-----"

        guard let beginRange = pemString.range(of: beginMarker),
              let endRange = pemString.range(of: endMarker) else {
            // Not PEM format, might be raw base64
            return Data(base64Encoded: pemString.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces))
        }

        let base64String = pemString[beginRange.upperBound..<endRange.lowerBound]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        return Data(base64Encoded: base64String)
    }
}

// MARK: - URLSession Delegate for Kubernetes Authentication

/// URLSession delegate that handles Kubernetes authentication challenges
final class KubernetesURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KubernetesURLSessionDelegate")

    // Properties accessed from nonisolated delegate methods
    nonisolated let authConfig: KubernetesAuthConfig

    /// Callback when WebSocket opens
    nonisolated(unsafe) var onOpen: (() -> Void)?

    /// Callback when WebSocket closes
    nonisolated(unsafe) var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    nonisolated init(authConfig: KubernetesAuthConfig) {
        self.authConfig = authConfig
        super.init()
    }

    // MARK: - URLSessionDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.logger.debug("Received authentication challenge: \(challenge.protectionSpace.authenticationMethod)")

        let authMethod = challenge.protectionSpace.authenticationMethod

        switch authMethod {
        case NSURLAuthenticationMethodServerTrust:
            // Server TLS validation
            handleServerTrustChallenge(challenge, completionHandler: completionHandler)

        case NSURLAuthenticationMethodClientCertificate:
            // Client certificate authentication
            handleClientCertificateChallenge(challenge, completionHandler: completionHandler)

        default:
            // Use default handling
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private nonisolated func handleServerTrustChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // If skip TLS verify is enabled, accept any certificate
        if authConfig.skipTLSVerify {
            Self.logger.warning("Skipping TLS verification (insecure)")
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            return
        }

        // If we have CA certificates, set them as anchors and use a basic X.509 policy
        // Kubernetes clusters use self-signed CAs with certificates that may not meet
        // Apple's strict SSL policy requirements (e.g., CN "kubernetes" without proper SANs).
        // When a custom CA is provided, we use BasicX509 policy which only validates
        // the certificate chain without strict hostname/compliance checks.
        if !authConfig.caCertificates.isEmpty {
            SecTrustSetAnchorCertificates(serverTrust, authConfig.caCertificates as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)

            // Use BasicX509 policy for custom CA - validates chain only, not hostname/compliance
            let basicPolicy = SecPolicyCreateBasicX509()
            SecTrustSetPolicies(serverTrust, basicPolicy)
            Self.logger.debug("Using BasicX509 policy for custom CA certificate validation")
        }

        // Evaluate the trust
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        if isValid {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            Self.logger.error("Server certificate validation failed: \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private nonisolated func handleClientCertificateChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let identity = authConfig.clientIdentity else {
            Self.logger.debug("No client certificate available")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Create credential with client identity
        let credential = URLCredential(
            identity: identity,
            certificates: nil,
            persistence: .forSession
        )
        completionHandler(.useCredential, credential)
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Self.logger.info("WebSocket opened with protocol: \(`protocol` ?? "none")")
        onOpen?()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        Self.logger.info("WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString ?? "none")")
        onClose?(closeCode, reason)
    }
}

// MARK: - Request Builder Extension

extension KubernetesAuthConfig {
    /// Create a URLRequest with proper authentication headers
    /// - Parameter url: The URL for the request
    /// - Returns: A URLRequest with authentication configured
    func createRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)

        // Add bearer token if available
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    /// Create a URLSession configured for this auth config
    /// - Returns: A configured URLSession
    func createSession() -> (URLSession, KubernetesURLSessionDelegate) {
        let delegate = KubernetesURLSessionDelegate(authConfig: self)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        return (session, delegate)
    }
}
