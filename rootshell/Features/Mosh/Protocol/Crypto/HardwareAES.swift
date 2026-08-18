//
//  HardwareAES.swift
//
//  Hardware-accelerated AES using CommonCrypto.
//  Uses Apple Silicon's dedicated AES instructions for ~100x faster
//  block operations compared to pure Swift implementations.
//

import Foundation
import CommonCrypto

/// Hardware-accelerated AES-128 block cipher using CommonCrypto.
/// This leverages Apple Silicon's dedicated crypto instructions.
enum HardwareAES {

    /// AES-128 block size in bytes
    static let blockSize = 16

    /// Creates a block encryption function for use with CryptoSwift's OCB mode.
    /// The returned closure encrypts a single 16-byte block using AES-128-ECB.
    ///
    /// - Parameter key: 16-byte AES-128 key
    /// - Returns: Block encryption function compatible with CipherOperationOnBlock
    static func blockEncryptor(key: [UInt8]) -> (ArraySlice<UInt8>) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128 else {
            return { _ in nil }
        }

        let keyCopy = key
        let zeroBlock = [UInt8](repeating: 0, count: blockSize)

        // OCB derives its key-dependent L_* value from AES(K, 0^128) every
        // time a worker is created. Cache that expensive operation once per
        // session while continuing to use unmodified CryptoSwift.
        guard let encryptedZeroBlock = crypt(
            operation: CCOperation(kCCEncrypt),
            key: keyCopy,
            block: zeroBlock[...]
        ) else {
            return { _ in nil }
        }

        return { block in
            guard block.count == blockSize else { return nil }
            if block.allSatisfy({ $0 == 0 }) {
                return encryptedZeroBlock
            }
            return crypt(operation: CCOperation(kCCEncrypt), key: keyCopy, block: block)
        }
    }

    /// Creates a block decryption function for use with CryptoSwift's OCB mode.
    /// The returned closure decrypts a single 16-byte block using AES-128-ECB.
    ///
    /// - Parameter key: 16-byte AES-128 key
    /// - Returns: Block decryption function compatible with CipherOperationOnBlock
    static func blockDecryptor(key: [UInt8]) -> (ArraySlice<UInt8>) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128 else {
            return { _ in nil }
        }

        let keyCopy = key

        return { block in
            crypt(operation: CCOperation(kCCDecrypt), key: keyCopy, block: block)
        }
    }

    private static func crypt(
        operation: CCOperation,
        key: [UInt8],
        block: ArraySlice<UInt8>
    ) -> [UInt8]? {
        guard block.count == blockSize else { return nil }

        var output = [UInt8](repeating: 0, count: blockSize)
        var dataOutMoved: size_t = 0

        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key,
            key.count,
            nil,
            Array(block),
            block.count,
            &output,
            output.count,
            &dataOutMoved
        )

        guard status == kCCSuccess, dataOutMoved == blockSize else {
            return nil
        }

        return output
    }
}
