#if !CHINA_BUILD
//
//  ChatGPTOAuth.swift
//  rootshell
//
//  OAuth 2.0 + PKCE against auth.openai.com, used to spend a ChatGPT
//  subscription on the Codex backend instead of a metered API key.
//

import CryptoKit
import Foundation
import Security
import os.log

// MARK: - Credentials

/// A ChatGPT-subscription token bundle. Persisted as JSON in the Keychain by
/// `ChatGPTCredentialStore`.
nonisolated struct ChatGPTCredentials: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry, epoch milliseconds.
    let expiresAt: Double
    /// `chatgpt_account_id`, the subscription pool the token draws limits from.
    let accountID: String
    let email: String?
    /// `chatgpt_plan_type`, e.g. "pro" / "plus" / "team".
    let planType: String?

    var expiryDate: Date {
        Date(timeIntervalSince1970: expiresAt / 1000)
    }
}

// MARK: - Errors

nonisolated enum ChatGPTAuthError: LocalizedError {
    case notSignedIn
    case portUnavailable
    case cancelled
    case stateMismatch
    case authorizationDenied(String)
    case tokenEndpoint(String)
    case missingFields
    case missingAccountID

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to ChatGPT"
        case .portUnavailable:
            return "Port 1455 is already in use. Quit any other app signing in to ChatGPT and try again."
        case .cancelled:
            return "Sign-in was cancelled"
        case .stateMismatch:
            return "Sign-in failed a security check (state mismatch)"
        case .authorizationDenied(let message):
            return "ChatGPT denied the sign-in: \(message)"
        case .tokenEndpoint(let message):
            return "Token request failed: \(message)"
        case .missingFields:
            return "Token response was missing required fields"
        case .missingAccountID:
            return "Could not read the ChatGPT account from the token"
        }
    }
}

// MARK: - OAuth

nonisolated enum ChatGPTOAuth {
    private static let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTOAuth")

    // Constants mirror the Codex CLI client registration; the values are fixed
    // by OpenAI and cannot be substituted.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    /// OpenAI allows exactly this redirect. A different host/port makes the token
    /// exchange fail with 403, so there is deliberately no fallback port.
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    /// Sent both as an authorize-URL parameter and as a request header; the two
    /// must agree. `codex_cli_rs` is the value the official Codex CLI sends.
    static let originator = "codex_cli_rs"
    /// Pinned `@openai/codex` version reported in the `version` header.
    static let clientVersion = "0.144.1"

    private static let authClaim = "https://api.openai.com/auth"
    private static let profileClaim = "https://api.openai.com/profile"
    private static let requestTimeout: TimeInterval = 15

    // MARK: PKCE

    struct PKCE {
        let verifier: String
        let challenge: String
    }

    static func generatePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(96))
        return PKCE(verifier: verifier, challenge: challenge(forVerifier: verifier))
    }

    /// S256: base64url(SHA-256(ASCII(verifier))).
    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func generateState() -> String {
        randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Authorization URL

    static func authorizationURL(state: String, challenge: String) -> URL {
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator)
        ]
        return components.url!
    }

    // MARK: Token endpoints

    static func exchangeCode(_ code: String, verifier: String) async throws -> ChatGPTCredentials {
        let form = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ]
        let token = try await postForm(form)

        let profile = tokenProfile(accessToken: token.access_token, idToken: token.id_token)
        guard let accountID = profile.accountID else {
            throw ChatGPTAuthError.missingAccountID
        }

        return ChatGPTCredentials(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresAt: Date().timeIntervalSince1970 * 1000 + token.expires_in * 1000,
            accountID: accountID,
            email: profile.email,
            planType: profile.planType
        )
    }

    /// Exchanges a refresh token. `previous` supplies the fields the refresh
    /// response omits; the workspace a credential is scoped to is fixed at login.
    static func refresh(
        refreshToken: String,
        previous: ChatGPTCredentials
    ) async throws -> ChatGPTCredentials {
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        let token = try await postForm(form)

        let profile = tokenProfile(accessToken: token.access_token, idToken: nil)

        return ChatGPTCredentials(
            accessToken: token.access_token,
            // Refresh tokens rotate; keep the old one only if none came back.
            refreshToken: token.refresh_token.isEmpty ? refreshToken : token.refresh_token,
            expiresAt: Date().timeIntervalSince1970 * 1000 + token.expires_in * 1000,
            accountID: profile.accountID ?? previous.accountID,
            email: profile.email ?? previous.email,
            planType: previous.planType
        )
    }

    private struct TokenResponse {
        let access_token: String
        let refresh_token: String
        let id_token: String?
        let expires_in: Double
    }

    private static func postForm(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = formatTokenEndpointError(status: http.statusCode, body: body)
            logger.error("Token endpoint failed: \(message, privacy: .public)")
            throw ChatGPTAuthError.tokenEndpoint(message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw ChatGPTAuthError.missingFields
        }

        return TokenResponse(
            access_token: accessToken,
            refresh_token: refreshToken,
            id_token: json["id_token"] as? String,
            expires_in: expiresIn
        )
    }

    /// Renders `{error, error_description}` or `{error: {code, message}}` as
    /// "<status> <code>: <message>".
    static func formatTokenEndpointError(status: Int, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\(status)" }

        guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return "\(status) \(trimmed)"
        }

        let error = describe(json["error"])
        let description = describe(json["error_description"])
        if let error, let description, error != description {
            return "\(status) \(error): \(description)"
        }
        return "\(status) \(error ?? description ?? describe(json["message"]) ?? trimmed)"
    }

    private static func describe(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        guard let dict = value as? [String: Any] else { return nil }

        let code = describe(dict["code"] ?? dict["error"])
        let message = describe(dict["message"] ?? dict["error_description"] ?? dict["description"])
        if let code, let message, code != message { return "\(code): \(message)" }
        return code ?? message
    }

    // MARK: JWT claims

    struct TokenProfile {
        let accountID: String?
        let email: String?
        let planType: String?
    }

    /// The ChatGPT workspace lives on the access token; the plan type may only
    /// appear on the id token.
    static func tokenProfile(accessToken: String, idToken: String?) -> TokenProfile {
        let payload = decodeJWT(accessToken)
        let idPayload = idToken.flatMap(decodeJWT)

        let auth = payload?[authClaim] as? [String: Any]
        let idAuth = idPayload?[authClaim] as? [String: Any]

        let accountID = (auth?["chatgpt_account_id"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let email = (payload?[profileClaim] as? [String: Any])?["email"] as? String
        let planType = (auth?["chatgpt_plan_type"] as? String)
            ?? (idAuth?["chatgpt_plan_type"] as? String)

        return TokenProfile(
            accountID: accountID,
            email: email?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty,
            planType: planType?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty
        )
    }

    /// Convenience for the request layer, which re-derives the account id from
    /// whatever access token it is about to send.
    static func accountID(fromAccessToken token: String) -> String? {
        tokenProfile(accessToken: token, idToken: nil).accountID
    }

    // MARK: Request headers

    /// The header set the Codex backend expects, shared by the responses client
    /// and model discovery. `accountID` is re-derived from the token being sent
    /// rather than read from storage.
    static func requestHeaders(accessToken: String, sessionID: String) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer \(accessToken)",
            "OpenAI-Beta": "responses=experimental",
            "originator": originator,
            "version": clientVersion,
            "User-Agent": userAgent,
            "session_id": sessionID,
            "conversation_id": sessionID,
            "x-client-request-id": sessionID
        ]
        if let accountID = accountID(fromAccessToken: accessToken) {
            headers["chatgpt-account-id"] = accountID
        }
        return headers
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if targetEnvironment(macCatalyst)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return "rootshell/\(version) (\(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }()

    private static func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Data(base64Encoded:) requires the padding a base64url JWT omits.
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
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

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
