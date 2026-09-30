#if !CHINA_BUILD
//
//  ChatGPTIDToken.swift
//  rootshell
//
//  OIDC ID-token validation: RS256 signature against OpenAI's published JWKS,
//  then issuer, audience, expiry, and nonce.
//

import Foundation
import Security

nonisolated enum ChatGPTIDToken {
    struct Claims: Sendable {
        let issuer: String
        let subject: String
        let email: String?
    }

    private static let clockSkew: TimeInterval = 60

    static func validate(
        _ token: String,
        clientID: String,
        nonce: String,
        discovery: ChatGPTOAuth.Discovery
    ) async throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = ChatGPTOAuth.base64URLDecode(parts[0]),
              let payloadData = ChatGPTOAuth.base64URLDecode(parts[1]),
              let signature = ChatGPTOAuth.base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTAuthError.invalidIDToken("malformed token")
        }

        guard header["alg"] as? String == "RS256" else {
            throw ChatGPTAuthError.invalidIDToken("unsupported algorithm")
        }

        let key = try await signingKey(kid: header["kid"] as? String, jwksURI: discovery.jwksURI)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            signature as CFData,
            nil
        ) else {
            throw ChatGPTAuthError.invalidIDToken("bad signature")
        }

        guard let issuer = payload["iss"] as? String, issuer == discovery.issuer else {
            throw ChatGPTAuthError.invalidIDToken("unexpected issuer")
        }

        let audiences: [String]
        if let single = payload["aud"] as? String {
            audiences = [single]
        } else {
            audiences = payload["aud"] as? [String] ?? []
        }
        guard audiences.contains(clientID) else {
            throw ChatGPTAuthError.invalidIDToken("unexpected audience")
        }

        guard let exp = (payload["exp"] as? NSNumber)?.doubleValue,
              Date().timeIntervalSince1970 < exp + clockSkew else {
            throw ChatGPTAuthError.invalidIDToken("expired")
        }

        guard payload["nonce"] as? String == nonce else {
            throw ChatGPTAuthError.invalidIDToken("nonce mismatch")
        }

        guard let subject = payload["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTAuthError.invalidIDToken("missing subject")
        }

        let email = (payload["email"] as? String)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        return Claims(issuer: issuer, subject: subject, email: email?.isEmpty == false ? email : nil)
    }

    // MARK: - JWKS

    private static func signingKey(kid: String?, jwksURI: URL) async throws -> SecKey {
        var request = URLRequest(url: jwksURI)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [[String: Any]] else {
            throw ChatGPTAuthError.discoveryFailed
        }

        let rsaKeys = keys.filter { $0["kty"] as? String == "RSA" }
        let match: [String: Any]?
        if let kid {
            match = rsaKeys.first { $0["kid"] as? String == kid }
        } else {
            match = rsaKeys.count == 1 ? rsaKeys.first : nil
        }

        guard let jwk = match,
              let modulus = (jwk["n"] as? String).flatMap(ChatGPTOAuth.base64URLDecode),
              let exponent = (jwk["e"] as? String).flatMap(ChatGPTOAuth.base64URLDecode) else {
            throw ChatGPTAuthError.invalidIDToken("unknown signing key")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let key = SecKeyCreateWithData(
            rsaPublicKeyDER(modulus: modulus, exponent: exponent) as CFData,
            attributes as CFDictionary,
            nil
        ) else {
            throw ChatGPTAuthError.invalidIDToken("unusable signing key")
        }
        return key
    }

    /// PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let body = derInteger(modulus) + derInteger(exponent)
        return Data([0x30]) + derLength(body.count) + body
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        // A set high bit would read as negative.
        if value[value.startIndex] & 0x80 != 0 {
            value.insert(0, at: value.startIndex)
        }
        return Data([0x02]) + derLength(value.count) + value
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
#endif
