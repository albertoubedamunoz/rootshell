#if !CHINA_BUILD
//
//  ChatGPTAuthCoordinator.swift
//  rootshell
//
//  Drives Sign in with ChatGPT: opens the authorize URL in a Safari-backed
//  session, catches the loopback redirect, exchanges the code, and validates
//  the ID token and granted scopes.
//

import AuthenticationServices
import Foundation
import UIKit
import os.log

/// Which registration a sign-in attempt targets.
enum ChatGPTSignInTarget: Sendable {
    /// Registers a new client via `dynamic_agent_client`.
    case newAccount
    /// Reauthorizes a saved registration with its issued client ID.
    /// `forceConsent` re-asks for ChatGPT plan permission after a decline.
    case existing(ChatGPTRegistration, forceConsent: Bool)
}

@MainActor
final class ChatGPTAuthCoordinator {
    private let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTAuth")

    /// ASWebAuthenticationSession requires a callback scheme, but ours is a
    /// loopback `http://` URL it cannot intercept. This placeholder never fires;
    /// the session is dismissed by hand once the listener has the code.
    private static let placeholderScheme = "rootshell-chatgpt"

    private let anchorProvider = ChatGPTPresentationAnchorProvider()
    private var session: ASWebAuthenticationSession?

    /// Runs the full flow and returns a validated registration with a session.
    /// The caller installs it with `ChatGPTCredentialStore.install`.
    func signIn(_ target: ChatGPTSignInTarget) async throws -> ChatGPTRegistration {
        let hostID = await ChatGPTCredentialStore.shared.hostID()
        let pkce = ChatGPTOAuth.generatePKCE()
        let state = ChatGPTOAuth.generateRandomToken()
        let nonce = ChatGPTOAuth.generateRandomToken()

        let mode: ChatGPTOAuth.AuthorizationMode
        switch target {
        case .newAccount:
            mode = .register
        case .existing(let registration, let forceConsent):
            mode = .reauthorize(
                clientID: registration.clientID,
                idTokenHint: registration.idToken,
                loginHint: registration.email,
                forceConsent: forceConsent
            )
        }

        let server = ChatGPTLoopbackServer()
        let port = try await server.start(expectedState: state)
        let redirectURI = ChatGPTOAuth.redirectURI(port: port)
        let authURL = ChatGPTOAuth.authorizationURL(
            mode: mode,
            hostID: hostID,
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            challenge: pkce.challenge
        )

        let session = ASWebAuthenticationSession(
            url: authURL,
            callback: .customScheme(Self.placeholderScheme)
        ) { _, error in
            // Only fires when the user dismisses the sheet — unblock the listener.
            if error != nil {
                server.stop()
            }
        }
        session.presentationContextProvider = anchorProvider
        // Sharing Safari cookies means an already-signed-in user approves in one tap.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session

        guard session.start() else {
            server.stop()
            self.session = nil
            throw ChatGPTAuthError.cancelled
        }

        defer {
            session.cancel()
            self.session = nil
        }

        let callback = try await server.waitForCallback()
        session.cancel()

        let clientID = try resolveClientID(target: target, callback: callback)

        logger.info("Received authorization code, exchanging for tokens")
        let tokens: ChatGPTOAuth.TokenResponse
        do {
            tokens = try await ChatGPTOAuth.exchangeCode(
                callback.code,
                verifier: pkce.verifier,
                clientID: clientID,
                redirectURI: redirectURI
            )
        } catch ChatGPTAuthError.tokenEndpoint(_, let code, _) where code == "invalid_grant" {
            // The code is spent; only a fresh authorization can recover.
            throw ChatGPTAuthError.authorizationFailed(String(localized: "the sign-in code expired. Try again."))
        }

        guard let idToken = tokens.idToken else {
            throw ChatGPTAuthError.invalidIDToken("missing ID token")
        }
        let discovery = try await ChatGPTOAuth.discovery()
        let claims = try await ChatGPTIDToken.validate(idToken, clientID: clientID, nonce: nonce, discovery: discovery)

        if case .existing(let registration, _) = target, registration.subject != claims.subject {
            throw ChatGPTAuthError.accountMismatch
        }

        let sessionTokens = tokens.session(fallbackScopes: callback.scopes ?? [])
        logger.info("Signed in to ChatGPT (plan usage \(sessionTokens.canUsePlan ? "granted" : "not granted", privacy: .public))")

        let existing: ChatGPTRegistration?
        if case .existing(let registration, _) = target { existing = registration } else { existing = nil }

        return ChatGPTRegistration(
            clientID: clientID,
            issuer: claims.issuer,
            subject: claims.subject,
            email: claims.email ?? existing?.email,
            label: existing?.label ?? "",
            idToken: idToken,
            session: sessionTokens
        )
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    /// New registrations must return an issued ID; reauthorization keeps the
    /// saved one and rejects a different one.
    private func resolveClientID(target: ChatGPTSignInTarget, callback: ChatGPTCallback) throws -> String {
        switch target {
        case .newAccount:
            guard let issued = callback.clientID, issued != ChatGPTOAuth.dynamicClientID else {
                throw ChatGPTAuthError.registrationIncomplete
            }
            return issued
        case .existing(let registration, _):
            if let returned = callback.clientID, returned != registration.clientID {
                throw ChatGPTAuthError.clientMismatch
            }
            return registration.clientID
        }
    }
}

// MARK: - Presentation anchor

private final class ChatGPTPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        let window = scenes
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first

        return window ?? ASPresentationAnchor()
    }
}
#endif
