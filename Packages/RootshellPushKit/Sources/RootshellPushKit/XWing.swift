//
//  XWing.swift
//  RootshellPushKit
//
//  X-Wing hybrid KEM (ML-KEM-768 + X25519) via the CXWing shim.
//

import CXWing
import Foundation

public enum XWing {
    public static let seedSize = Int(CXWING_SEED_BYTES)
    public static let publicKeySize = Int(CXWING_PUBLIC_KEY_BYTES)
    public static let encapsulationSize = Int(CXWING_CIPHERTEXT_BYTES)
    public static let sharedSecretSize = Int(CXWING_SHARED_SECRET_BYTES)

    public struct PublicKey: Sendable, Equatable {
        public let rawRepresentation: Data

        public init(rawRepresentation: Data) throws {
            guard rawRepresentation.count == XWing.publicKeySize else { throw PushCryptoError.badKeySize }
            self.rawRepresentation = rawRepresentation
        }

        /// Returns (sharedSecret, encapsulation).
        public func encapsulate() throws -> (Data, Data) {
            var ct = Data(count: XWing.encapsulationSize)
            var ss = Data(count: XWing.sharedSecretSize)
            let ok = ct.withUnsafeMutableBytes { ctPtr in
                ss.withUnsafeMutableBytes { ssPtr in
                    rawRepresentation.withUnsafeBytes { pkPtr in
                        cxwing_encap(ctPtr.baseAddress, ssPtr.baseAddress, pkPtr.baseAddress)
                    }
                }
            }
            guard ok == 1 else { throw PushCryptoError.kemFailure }
            return (ss, ct)
        }
    }

    public struct PrivateKey: Sendable {
        /// 32-byte seed; the only thing that needs persisting.
        public let seed: Data
        public let publicKey: PublicKey

        public init() throws {
            var seed = Data(count: XWing.seedSize)
            let status = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, XWing.seedSize, $0.baseAddress!) }
            guard status == errSecSuccess else { throw PushCryptoError.randomFailure }
            try self.init(seed: seed)
        }

        public init(seed: Data) throws {
            guard seed.count == XWing.seedSize else { throw PushCryptoError.badKeySize }
            var pk = Data(count: XWing.publicKeySize)
            let ok = pk.withUnsafeMutableBytes { pkPtr in
                seed.withUnsafeBytes { seedPtr in
                    cxwing_public_from_seed(pkPtr.baseAddress, seedPtr.baseAddress)
                }
            }
            guard ok == 1 else { throw PushCryptoError.kemFailure }
            self.seed = seed
            self.publicKey = try PublicKey(rawRepresentation: pk)
        }

        public func decapsulate(_ encapsulation: Data) throws -> Data {
            guard encapsulation.count == XWing.encapsulationSize else { throw PushCryptoError.badEncapsulation }
            var ss = Data(count: XWing.sharedSecretSize)
            let ok = ss.withUnsafeMutableBytes { ssPtr in
                encapsulation.withUnsafeBytes { ctPtr in
                    seed.withUnsafeBytes { seedPtr in
                        cxwing_decap(ssPtr.baseAddress, ctPtr.baseAddress, seedPtr.baseAddress)
                    }
                }
            }
            guard ok == 1 else { throw PushCryptoError.kemFailure }
            return ss
        }
    }
}

public enum PushCryptoError: Error, Equatable {
    case badKeySize
    case noPrivateKey
    case badEncapsulation
    case kemFailure
    case randomFailure
    case malformed(String)
    case authenticationFailure
    case headerTooLarge
}
