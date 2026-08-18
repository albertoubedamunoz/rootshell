import CryptoKit
import Foundation

/// Builds the self-signed OpenSSH user certificate that carries an OpenPubkey
/// PK token, byte-compatible with what `opkssh login` produces via Go
/// x/crypto/ssh.
///
/// The certificate is signed by the ephemeral key itself (no CA): the trust
/// comes from the PK token in the `openpubkey-pkt` extension, which the
/// server-side verifier validates against the OIDC provider. `validBefore`
/// is infinity by design; the real ~24h lifetime is enforced server-side
/// from the ID token, and the app tracks renewal via the token's exp claim.
///
/// Serialization is canonical (sorted tuple maps, minimal mpints), matching
/// both Go's marshaler and NIOSSH's re-serializer, so the signature stays
/// valid when NIOSSH re-encodes the parsed certificate during auth.
nonisolated enum OpkSSHCertBuilder {
    static let wildcardPrincipal = "opkssh-wildcard"
    static let pktExtensionName = "openpubkey-pkt"
    static let accessTokenExtensionName = "openpubkey-act"

    struct Output: Sendable {
        /// Raw certificate wire blob (what NIOSSHCertifiedPublicKey parses).
        let certificateBlob: Data
        /// One-liner authorized_keys form: "<type> <base64> openpubkey".
        let certLine: String
    }

    static func buildCertificate(
        ephemeralKey: OpenPubkeyEphemeralKey,
        keyID: String,
        compactPKT: String,
        accessToken: String?
    ) throws -> Output {
        var nonce = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)
        return try buildCertificate(
            ephemeralKey: ephemeralKey,
            keyID: keyID,
            compactPKT: compactPKT,
            accessToken: accessToken,
            nonce: Data(nonce)
        )
    }

    /// Deterministic-nonce variant for the self-test.
    static func buildCertificate(
        ephemeralKey: OpenPubkeyEphemeralKey,
        keyID: String,
        compactPKT: String,
        accessToken: String?,
        nonce: Data
    ) throws -> Output {
        var extensions: [String: String] = [
            "permit-X11-forwarding": "",
            "permit-agent-forwarding": "",
            "permit-port-forwarding": "",
            "permit-pty": "",
            "permit-user-rc": "",
            pktExtensionName: compactPKT,
        ]
        if let accessToken {
            extensions[accessTokenExtensionName] = accessToken
        }

        let certType = ephemeralKey.sshCertType

        var writer = SSHWireWriter()
        writer.writeString(certType)
        writer.writeString(nonce)
        ephemeralKey.writeCertPublicKey(into: &writer)
        writer.writeUInt64(0)                          // serial
        writer.writeUInt32(1)                          // type: user
        writer.writeString(keyID)
        writer.writeString(packedStrings([wildcardPrincipal]))
        writer.writeUInt64(0)                          // validAfter
        writer.writeUInt64(UInt64.max)                 // validBefore: forever
        writer.writeString(packedTuples([:]))          // critical options
        writer.writeString(packedTuples(extensions))
        writer.writeString(Data())                     // reserved
        writer.writeString(ephemeralKey.signatureKeyBlob)

        // Self-signature over everything written so far.
        let signature = try ephemeralKey.certSignatureBlob(over: writer.data)
        writer.writeString(signature)

        let blob = writer.data
        let line = "\(certType) \(blob.base64EncodedString()) openpubkey"
        return Output(certificateBlob: blob, certLine: line)
    }

    // MARK: - Components

    /// Principals field: concatenated SSH strings inside the outer string.
    private static func packedStrings(_ values: [String]) -> Data {
        var writer = SSHWireWriter()
        for value in values {
            writer.writeString(value)
        }
        return writer.data
    }

    /// Options/extensions tuple encoding, matching Go x/crypto marshalTuples
    /// and NIOSSH writeMapStringString: keys byte-sorted; each tuple is
    /// string(key) + string(value-field) where a non-empty value is wrapped
    /// in an inner string and an empty value is a zero-length field.
    private static func packedTuples(_ tuples: [String: String]) -> Data {
        var writer = SSHWireWriter()
        for key in tuples.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            writer.writeString(key)
            let value = tuples[key]!
            if value.isEmpty {
                writer.writeUInt32(0)
            } else {
                var inner = SSHWireWriter()
                inner.writeString(value)
                writer.writeString(inner.data)
            }
        }
        return writer.data
    }
}

/// Minimal SSH wire-format writer (RFC 4251 primitives).
nonisolated struct SSHWireWriter {
    private(set) var data = Data()

    mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeString(_ bytes: some Collection<UInt8>) {
        writeUInt32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func writeString(_ string: String) {
        writeString(Data(string.utf8))
    }

    /// Positive mpint: strip leading zeros, prepend 0x00 if the high bit is
    /// set so the value can't be read as negative.
    mutating func writeMPInt(_ bytes: some Collection<UInt8>) {
        var trimmed = Array(bytes.drop(while: { $0 == 0 }))
        if let first = trimmed.first, first & 0x80 != 0 {
            trimmed.insert(0, at: 0)
        }
        writeString(trimmed)
    }
}
