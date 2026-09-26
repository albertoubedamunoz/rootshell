//
//  MoshOCBCryptor.swift
//  rootshell
//
//  Owns a MoshOCB.c context: AES-128-OCB on complete Mosh packet payloads.
//

import Foundation

nonisolated final class MoshOCBCryptor {
    static let nonceLength = Int(MOSH_OCB_NONCE_LENGTH)
    static let tagLength = Int(MOSH_OCB_TAG_LENGTH)

    private let context: OpaquePointer

    init?(key: [UInt8]) {
        guard key.count == Int(MOSH_OCB_KEY_LENGTH),
              let context = key.withUnsafeBufferPointer({ mosh_ocb_create($0.baseAddress) }) else {
            return nil
        }
        self.context = context
    }

    deinit {
        mosh_ocb_free(context)
    }

    /// Returns `header` followed by the ciphertext and tag.
    func seal(_ plaintext: Data, nonce: [UInt8], header: Data) -> Data? {
        guard nonce.count == Self.nonceLength else { return nil }
        var packet = header
        let start = packet.count
        packet.count += plaintext.count + Self.tagLength
        let status = packet.withUnsafeMutableBytes { out in
            plaintext.withUnsafeBytes { input in
                mosh_ocb_encrypt(
                    context,
                    nonce,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    input.count,
                    out.bindMemory(to: UInt8.self).baseAddress! + start
                )
            }
        }
        return status == 0 ? packet : nil
    }

    /// Decrypts `packet[offset...]` (ciphertext plus tag); nil if the tag does not verify.
    func open(_ packet: Data, from offset: Int, nonce: [UInt8]) -> Data? {
        let sealedCount = packet.count - offset
        guard nonce.count == Self.nonceLength, offset >= 0, sealedCount >= Self.tagLength else {
            return nil
        }
        var plaintext = Data(count: sealedCount - Self.tagLength)
        let status = plaintext.withUnsafeMutableBytes { out in
            packet.withUnsafeBytes { input in
                mosh_ocb_decrypt(
                    context,
                    nonce,
                    input.bindMemory(to: UInt8.self).baseAddress! + offset,
                    sealedCount,
                    out.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return status == 0 ? plaintext : nil
    }
}
