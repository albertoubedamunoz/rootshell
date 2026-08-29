//
//  HPKE.swift
//  RootshellPushKit
//
//  RFC 9180 base mode over X-Wing, HKDF-SHA256, AES-256-GCM. CryptoKit's HPKE
//  cannot take a custom KEM below OS 26, so the key schedule lives here.
//

import CryptoKit
import Foundation

enum PushHPKE {
    static let kemID: UInt16 = 0x647a
    static let kdfID: UInt16 = 0x0001
    static let aeadID: UInt16 = 0x0002
    static let keySize = 32
    static let nonceSize = 12

    static let suiteID: Data = {
        var d = Data("HPKE".utf8)
        d.append(contentsOf: be16(kemID))
        d.append(contentsOf: be16(kdfID))
        d.append(contentsOf: be16(aeadID))
        return d
    }()

    struct Context {
        let key: SymmetricKey
        let baseNonce: Data
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

    static func labeledExtract(salt: Data, label: String, ikm: Data) -> HashedAuthenticationCode<SHA256> {
        var input = Data("HPKE-v1".utf8)
        input.append(suiteID)
        input.append(Data(label.utf8))
        input.append(ikm)
        return HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: input), salt: salt)
    }

    static func labeledExpand(prk: HashedAuthenticationCode<SHA256>, label: String, info: Data, length: Int) -> Data {
        var labeledInfo = Data(be16(UInt16(length)))
        labeledInfo.append(Data("HPKE-v1".utf8))
        labeledInfo.append(suiteID)
        labeledInfo.append(Data(label.utf8))
        labeledInfo.append(info)
        let out = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: labeledInfo, outputByteCount: length)
        return out.withUnsafeBytes { Data($0) }
    }

    /// mode_base with no PSK.
    static func keySchedule(sharedSecret: Data, info: Data) -> Context {
        let pskIDHash = labeledExtract(salt: Data(), label: "psk_id_hash", ikm: Data())
        let infoHash = labeledExtract(salt: Data(), label: "info_hash", ikm: info)
        var ctx = Data([0x00])
        ctx.append(pskIDHash.withUnsafeBytes { Data($0) })
        ctx.append(infoHash.withUnsafeBytes { Data($0) })
        let secret = labeledExtract(salt: sharedSecret, label: "secret", ikm: Data())
        let key = labeledExpand(prk: secret, label: "key", info: ctx, length: keySize)
        let nonce = labeledExpand(prk: secret, label: "base_nonce", info: ctx, length: nonceSize)
        return Context(key: SymmetricKey(data: key), baseNonce: nonce)
    }

    /// Single-shot seal (sequence number 0).
    static func seal(to pk: XWing.PublicKey, info: Data, aad: Data, plaintext: Data) throws -> (enc: Data, ct: Data) {
        let (ss, enc) = try pk.encapsulate()
        let ctx = keySchedule(sharedSecret: ss, info: info)
        let box = try AES.GCM.seal(plaintext, using: ctx.key, nonce: AES.GCM.Nonce(data: ctx.baseNonce), authenticating: aad)
        return (enc, box.ciphertext + box.tag)
    }

    static func open(with sk: XWing.PrivateKey, enc: Data, info: Data, aad: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw PushCryptoError.malformed("ciphertext") }
        let ss = try sk.decapsulate(enc)
        let ctx = keySchedule(sharedSecret: ss, info: info)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: ctx.baseNonce),
                                        ciphertext: ciphertext.dropLast(16),
                                        tag: ciphertext.suffix(16))
        do {
            return try AES.GCM.open(box, using: ctx.key, authenticating: aad)
        } catch {
            throw PushCryptoError.authenticationFailure
        }
    }
}
