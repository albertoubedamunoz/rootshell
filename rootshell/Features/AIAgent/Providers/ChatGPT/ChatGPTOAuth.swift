#if !CHINA_BUILD
//
//  ChatGPTOAuth.swift
//  rootshell
//
//  Sign in with ChatGPT for open-source apps: dynamic client registration,
//  OAuth 2.0 + PKCE + OIDC against auth.openai.com, and ChatGPT plan usage on
//  the public Responses API. https://developers.openai.com/siwc
//

import Foundation
import Security
import CryptoKit
import os.log

// MARK: - Credentials

/// One issued client registration: a ChatGPT account and workspace that
/// authorized rootshell. Persisted as JSON in the Keychain by
/// `ChatGPTCredentialStore`.
nonisolated struct ChatGPTRegistration: Codable, Equatable, Identifiable, Sendable {
    /// The issued `oaiapp_…` client ID, never `dynamic_agent_client`.
    let clientID: String
    let issuer: String
    /// Validated ID-token `sub`.
    let subject: String
    var email: String?
    /// Stable, distinct name for the account picker.
    var label: String
    /// Retained for `id_token_hint`; cleared on sign-out.
    var idToken: String?
    /// nil while signed out; the registration itself is kept for reuse.
    var session: ChatGPTSession?

    var id: String { clientID }
    var isSignedIn: Bool { session != nil }
    var canUsePlan: Bool { session?.canUsePlan ?? false }
}

/// The renewable token set for one registration.
nonisolated struct ChatGPTSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let scopes: [String]
    /// Absolute expiry, epoch milliseconds.
    let expiresAt: Double
    /// When the token response arrived, epoch milliseconds.
    let savedAt: Double

    var expiryDate: Date {
        Date(timeIntervalSince1970: expiresAt / 1000)
    }

    /// A valid sign-in alone does not authorize plan usage; the scope must be granted.
    var canUsePlan: Bool {
        scopes.contains(ChatGPTOAuth.planScope)
    }
}

// MARK: - Errors

nonisolated enum ChatGPTAuthError: LocalizedError {
    case notSignedIn
    case planNotEnabled
    case listenerUnavailable
    case cancelled
    case stateMismatch
    case accessDenied
    case authorizationFailed(String)
    case registrationIncomplete
    case clientMismatch
    case accountMismatch
    case tokenEndpoint(status: Int, code: String?, message: String)
    case missingFields
    case invalidIDToken(String)
    case sessionExpired
    case invalidClient
    case discoveryFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "Not signed in to ChatGPT")
        case .planNotEnabled:
            return String(localized: "ChatGPT plan use isn't enabled for this account. Enable it in Settings, or use an API key instead.")
        case .listenerUnavailable:
            return String(localized: "Couldn't start the sign-in listener. Try again.")
        case .cancelled:
            return String(localized: "Sign-in was cancelled")
        case .stateMismatch:
            return String(localized: "Sign-in failed a security check (state mismatch)")
        case .accessDenied:
            return String(localized: "Access was declined. Continue with ChatGPT to try again, or use an API key instead.")
        case .authorizationFailed(let message):
            return String(localized: "ChatGPT sign-in failed: \(message)")
        case .registrationIncomplete:
            return String(localized: "ChatGPT didn't finish registering rootshell. Try again.")
        case .clientMismatch:
            return String(localized: "ChatGPT returned a different app registration than expected. Try again.")
        case .accountMismatch:
            return String(localized: "You signed in to a different ChatGPT account than the one selected. Use \"Use a Different Account\" to add it.")
        case .tokenEndpoint(let status, let code, let message):
            let prefix = code.map { "\(status) \($0)" } ?? "\(status)"
            return String(localized: "Token request failed: \(prefix): \(message)")
        case .missingFields:
            return String(localized: "Token response was missing required fields")
        case .invalidIDToken(let reason):
            return String(localized: "ChatGPT sign-in could not be verified: \(reason)")
        case .sessionExpired:
            return String(localized: "Your ChatGPT sign-in expired. Continue with ChatGPT in Settings to sign in again.")
        case .invalidClient:
            return String(localized: "ChatGPT no longer recognizes this app registration. Use a different account to register again.")
        case .discoveryFailed:
            return String(localized: "Couldn't reach OpenAI's sign-in service. Check your connection and try again.")
        }
    }
}

// MARK: - OAuth

nonisolated enum ChatGPTOAuth {
    private static let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTOAuth")

    static let issuer = "https://auth.openai.com"
    static let discoveryURL = "https://auth.openai.com/.well-known/openid-configuration"
    static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    static let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"

    /// First-time registration entrypoint; never saved or used for token exchange.
    static let dynamicClientID = "dynamic_agent_client"
    /// Sent as `agent_name_hint` on registration only.
    static let agentName = "rootshell"

    static let resource = "https://api.openai.com/v1"
    static let apiBaseURL = "https://api.openai.com"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scope = "openid profile email offline_access resource.invoke \(planScope)"

    /// Preferred loopback port; any free port works, only the port may vary.
    static let preferredCallbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"

    /// Where users review app usage and per-app limits.
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    private static let requestTimeout: TimeInterval = 15

    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    // MARK: PKCE, state, nonce

    struct PKCE {
        let verifier: String
        let challenge: String
    }

    static func generatePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(64))
        return PKCE(verifier: verifier, challenge: challenge(forVerifier: verifier))
    }

    /// S256: base64url(SHA-256(ASCII(verifier))).
    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func generateRandomToken() -> String {
        base64URL(randomBytes(32))
    }

    // MARK: Authorization URL

    enum AuthorizationMode: Sendable {
        case register
        case reauthorize(clientID: String, idTokenHint: String?, loginHint: String?, forceConsent: Bool)

        var clientID: String {
            switch self {
            case .register: return ChatGPTOAuth.dynamicClientID
            case .reauthorize(let clientID, _, _, _): return clientID
            }
        }
    }

    static func authorizationURL(
        mode: AuthorizationMode,
        hostID: String,
        redirectURI: String,
        state: String,
        nonce: String,
        challenge: String
    ) -> URL {
        var fields: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", mode.clientID),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("resource", resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("ext_agent_host_id", hostID)
        ]
        switch mode {
        case .register:
            fields.append(("agent_name_hint", agentName))
        case .reauthorize(_, let idTokenHint, let loginHint, let forceConsent):
            if let idTokenHint { fields.append(("id_token_hint", idTokenHint)) }
            if let loginHint { fields.append(("login_hint", loginHint)) }
            if forceConsent { fields.append(("prompt", "consent")) }
        }
        return URL(string: authorizeURL + "?" + formEncode(fields))!
    }

    // MARK: Token endpoint

    struct TokenResponse: Sendable {
        let accessToken: String
        let refreshToken: String
        let idToken: String?
        let expiresIn: Double
        /// nil when the response omits `scope`.
        let scopes: [String]?

        func session(fallbackScopes: [String]) -> ChatGPTSession {
            let now = Date().timeIntervalSince1970 * 1000
            return ChatGPTSession(
                accessToken: accessToken,
                refreshToken: refreshToken,
                scopes: scopes ?? fallbackScopes,
                expiresAt: now + expiresIn * 1000,
                savedAt: now
            )
        }
    }

    static func exchangeCode(
        _ code: String,
        verifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> TokenResponse {
        try await postToken([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", resource)
        ])
    }

    /// Omits `scope` so the refresh keeps the original grant.
    static func refresh(refreshToken: String, clientID: String) async throws -> TokenResponse {
        try await postToken([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("resource", resource)
        ])
    }

    private static func postToken(_ fields: [(String, String)]) async throws -> TokenResponse {
        let (data, status) = try await postForm(url: URL(string: tokenURL)!, fields: fields)

        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let error = parseTokenEndpointError(body)
            logger.error("Token endpoint failed: \(status) \(error.code ?? "-", privacy: .public)")
            throw ChatGPTAuthError.tokenEndpoint(status: status, code: error.code, message: error.message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw ChatGPTAuthError.missingFields
        }

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: json["id_token"] as? String,
            expiresIn: expiresIn,
            scopes: (json["scope"] as? String).map(parseScopes)
        )
    }

    static func parseScopes(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
    }

    /// Reads `{error, error_description}` or `{error: {code, message}}`.
    static func parseTokenEndpointError(_ body: String) -> (code: String?, message: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return (nil, trimmed)
        }
        if let nested = json["error"] as? [String: Any] {
            let code = nested["code"] as? String
            return (code, (nested["message"] as? String) ?? code ?? trimmed)
        }
        let code = json["error"] as? String
        let message = (json["error_description"] as? String) ?? (json["detail"] as? String) ?? code ?? trimmed
        return (code, message)
    }

    // MARK: Revocation

    /// Revokes the renewable session. Returns false when revocation could not
    /// be confirmed after retrying network and 5xx failures.
    static func revoke(refreshToken: String, clientID: String) async -> Bool {
        let fields = [
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", clientID)
        ]
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(Double(attempt * 2)))
            }
            do {
                let endpoint = try await discovery().revocationEndpoint
                let (_, status) = try await postForm(url: endpoint, fields: fields)
                if status == 200 { return true }
                if status < 500 {
                    logger.error("Revocation rejected with HTTP \(status)")
                    return false
                }
            } catch {
                logger.warning("Revocation attempt failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return false
    }

    // MARK: Discovery

    struct Discovery: Sendable {
        let issuer: String
        let jwksURI: URL
        let revocationEndpoint: URL
    }

    static func discovery() async throws -> Discovery {
        var request = URLRequest(url: URL(string: discoveryURL)!)
        request.timeoutInterval = requestTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = json["issuer"] as? String,
              let jwks = (json["jwks_uri"] as? String).flatMap(URL.init(string:)),
              let revocation = (json["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw ChatGPTAuthError.discoveryFailed
        }
        return Discovery(issuer: issuer, jwksURI: jwks, revocationEndpoint: revocation)
    }

    // MARK: HTTP

    private static func postForm(url: URL, fields: [(String, String)]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(fields).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Strict RFC 3986 encoding; URLComponents leaves `+`, `@`, `/` and `:` bare.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ fields: [(String, String)]) -> String {
        fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }

    // MARK: Helpers

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // SecRandomCopyBytes effectively never fails; fall back rather than trap.
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: some StringProtocol) -> Data? {
        var value = String(string)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: value)
    }
}
#endif
