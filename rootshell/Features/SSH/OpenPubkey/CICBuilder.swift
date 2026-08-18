import CryptoKit
import Foundation

/// Client Instance Claims (CIC) for the OpenPubkey protocol.
///
/// The CIC binds the ephemeral public key to the OIDC ID token: its hash is
/// sent as the OIDC `nonce`, and the same JSON later becomes the protected
/// header of the client's JWS over the ID token payload.
///
/// The opkssh verifier recomputes the hash by re-marshaling the parsed header
/// with Go's `json.Marshal` (lexicographically sorted keys, compact, ASCII
/// values). We build the JSON with exactly that shape and reuse the same
/// bytes for both the nonce hash and the transmitted protected header, so
/// client and server always agree.
nonisolated struct OpenPubkeyCIC: Sendable {
    /// 64 lowercase hex chars (32 random bytes), the "rz" claim.
    let rz: String
    /// Exact protected-header JSON bytes (sorted keys, compact).
    let protectedJSON: Data
    /// base64url-nopad of `protectedJSON`; the CIC JWS protected segment.
    let protectedB64: String
    /// base64url-nopad(SHA3-256(protectedJSON)); the OIDC nonce.
    let nonce: String

    static func generate(for key: OpenPubkeyEphemeralKey) -> OpenPubkeyCIC {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let rz = randomBytes.map { String(format: "%02x", $0) }.joined()
        return OpenPubkeyCIC(rz: rz, key: key)
    }

    /// Deterministic variant used by the self-test (fixed rz).
    init(rz: String, key: OpenPubkeyEphemeralKey) {
        self.rz = rz

        // Go json.Marshal key order: top level alg < rz < typ < upk; the upk
        // JWK fields are likewise alphabetical (see OpenPubkeyEphemeralKey).
        // All values are plain ASCII, so no escaping differences are possible.
        let json = #"{"alg":"\#(key.jwsAlg)","rz":"\#(rz)","typ":"CIC","upk":"#
            + key.upkJWKFragment + "}"
        let jsonData = Data(json.utf8)

        self.protectedJSON = jsonData
        self.protectedB64 = jsonData.base64URLEncodedString()
        self.nonce = SHA3.sha3_256(jsonData).base64URLEncodedString()
    }
}
