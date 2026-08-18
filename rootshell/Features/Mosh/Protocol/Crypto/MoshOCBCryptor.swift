//
//  MoshOCBCryptor.swift
//  rootshell
//
//  One-shot adapter between Mosh packets and CryptoSwift's public OCB worker API.
//

import Foundation
import CryptoSwift

/// Encrypts and authenticates complete Mosh packet payloads with AES-128-OCB.
///
/// CryptoSwift exposes its OCB worker and finalization protocols publicly, but
/// its generic block encryptor/decryptor initializers are package-internal.
/// Mosh always processes a complete packet at once, so this small adapter is
/// sufficient and avoids carrying a CryptoSwift fork just to expose them.
@MainActor
enum MoshOCBCryptor {
    private static let blockSize = 16
    private static let tagLength = 16

    enum Error: LocalizedError {
        case invalidCiphertext
        case unsupportedWorker

        var errorDescription: String? {
            switch self {
            case .invalidCiphertext:
                return "OCB ciphertext is shorter than its authentication tag"
            case .unsupportedWorker:
                return "CryptoSwift returned an OCB worker without finalization support"
            }
        }
    }

    static func encrypt(
        _ plaintext: [UInt8],
        nonce: [UInt8],
        encryptBlock: @escaping CipherOperationOnBlock
    ) throws -> [UInt8] {
        let ocb = OCB(nonce: nonce, tagLength: tagLength, mode: .combined)
        let baseWorker = try ocb.worker(
            blockSize: blockSize,
            cipherOperation: encryptBlock,
            encryptionOperation: encryptBlock
        )

        guard var worker = baseWorker as? any FinalizingEncryptModeWorker else {
            throw Error.unsupportedWorker
        }

        var ciphertext: [UInt8] = []
        ciphertext.reserveCapacity(plaintext.count + tagLength)

        for start in stride(from: 0, to: plaintext.count, by: blockSize) {
            let end = min(start + blockSize, plaintext.count)
            ciphertext += worker.encrypt(block: plaintext[start..<end])
        }

        return Array(try worker.finalize(encrypt: ciphertext[...]))
    }

    static func decrypt(
        _ combinedCiphertext: [UInt8],
        nonce: [UInt8],
        encryptBlock: @escaping CipherOperationOnBlock,
        decryptBlock: @escaping CipherOperationOnBlock
    ) throws -> [UInt8] {
        guard combinedCiphertext.count >= tagLength else {
            throw Error.invalidCiphertext
        }

        let ocb = OCB(nonce: nonce, tagLength: tagLength, mode: .combined)
        let baseWorker = try ocb.worker(
            blockSize: blockSize,
            cipherOperation: decryptBlock,
            encryptionOperation: encryptBlock
        )

        guard var worker = baseWorker as? any FinalizingDecryptModeWorker else {
            throw Error.unsupportedWorker
        }

        let ciphertext = try worker.willDecryptLast(bytes: combinedCiphertext[...])
        var plaintext: [UInt8] = []
        plaintext.reserveCapacity(ciphertext.count)

        var start = ciphertext.startIndex
        while start < ciphertext.endIndex {
            let end = ciphertext.index(
                start,
                offsetBy: blockSize,
                limitedBy: ciphertext.endIndex
            ) ?? ciphertext.endIndex
            plaintext += worker.decrypt(block: ciphertext[start..<end])
            start = end
        }

        // Do not expose plaintext until CryptoSwift has authenticated the tag.
        return Array(try worker.didDecryptLast(bytes: plaintext[...]))
    }
}
