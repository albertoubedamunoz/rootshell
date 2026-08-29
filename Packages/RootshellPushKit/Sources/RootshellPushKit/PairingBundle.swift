//
//  PairingBundle.swift
//  RootshellPushKit
//
//  `rspair1.<base64url json>` handed from the device to a computer.
//

import Foundation

public struct PairingBundle: Codable, Sendable, Equatable {
    public static let prefix = "rspair1."
    public static let credentialPrefix = "rsc1."

    public var server: String
    public var label: String?
    public var senderCred: String
    public var publicKey: Data

    enum CodingKeys: String, CodingKey {
        case server, label
        case senderCred = "cred"
        case publicKey = "pk"
    }

    public init(server: String, label: String?, senderCred: String, publicKey: Data) {
        self.server = server; self.label = label; self.senderCred = senderCred; self.publicKey = publicKey
    }

    public func encoded() throws -> String {
        try validate()
        return try Self.prefix + PushJSON.encoder.encode(self).base64URLEncodedString()
    }

    public init(encoded: String) throws {
        let s = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(Self.prefix), let raw = Data(base64URL: String(s.dropFirst(Self.prefix.count))) else {
            throw PushCryptoError.malformed("pairing")
        }
        self = try PushJSON.decoder.decode(PairingBundle.self, from: raw)
        try validate()
    }

    func validate() throws {
        guard let u = URL(string: server), u.scheme == "https", u.host != nil, u.user == nil, u.query == nil, u.fragment == nil,
              senderCred.hasPrefix(Self.credentialPrefix), publicKey.count == XWing.publicKeySize else {
            throw PushCryptoError.malformed("pairing")
        }
    }
}
