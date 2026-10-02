//
//  CaptureCertificateBuilder.swift
//  rootshell
//
//  Minimal X.509 v3 builder for the HTTP capture CA and its self-test leaf.
//  ECDSA P-256 / SHA-256 only, which is all capture needs.
//

#if !CHINA_BUILD

import CryptoKit
import Foundation
import Security

nonisolated enum CaptureCertificateBuilder {
    struct Subject {
        var commonName: String
        var organization: String? = nil
    }

    /// Self-signed CA: BasicConstraints CA (critical), KeyUsage keyCertSign + cRLSign (critical).
    static func makeCA(subject: Subject, key: P256.Signing.PrivateKey, validFor years: Int = 10) throws -> Data {
        let now = Date()
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: years, to: now) ?? now.addingTimeInterval(Double(years) * 365 * 86400)
        let name = encodeName(subject)
        let spki = subjectPublicKeyInfo(key.publicKey)
        let extensions: [Data] = [
            ext(oid: OID.basicConstraints, critical: true, value: CaptureDER.sequence([CaptureDER.boolean(true)])),
            ext(oid: OID.keyUsage, critical: true, value: CaptureDER.bitString(Data([0x06]), unusedBits: 1)),
            ext(oid: OID.subjectKeyIdentifier, critical: false, value: CaptureDER.octetString(keyIdentifier(key.publicKey))),
        ]
        return try sign(
            serial: randomSerial(),
            issuer: name,
            subject: name,
            notBefore: now.addingTimeInterval(-86400),
            notAfter: notAfter,
            spki: spki,
            extensions: extensions,
            signer: .p256(key)
        )
    }

    /// Signs TBS bytes with the CA key (P-256 via CryptoKit, or an imported RSA SecKey).
    struct Signer {
        var algorithm: Data
        var sign: (Data) throws -> Data

        static func p256(_ key: P256.Signing.PrivateKey) -> Signer {
            Signer(algorithm: CaptureDER.sequence([CaptureDER.oid(OID.ecdsaWithSHA256)])) {
                try key.signature(for: $0).derRepresentation
            }
        }

        static func rsa(_ key: SecKey) -> Signer {
            Signer(algorithm: CaptureDER.sequence([CaptureDER.oid(OID.sha256WithRSA), CaptureDER.null()])) { tbs in
                var error: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) else {
                    throw error?.takeRetainedValue() ?? CocoaError(.coderInvalidValue)
                }
                return sig as Data
            }
        }
    }

    /// Leaf for `dnsName` signed by the CA (used to test whether the OS trusts it).
    static func makeLeaf(dnsName: String, leafKey: P256.Signing.PublicKey, caCertificate: Data, signer: Signer) throws -> Data {
        guard let issuer = issuerName(ofCertificate: caCertificate) else { throw CocoaError(.coderInvalidValue) }
        let now = Date()
        let extensions: [Data] = [
            ext(oid: OID.basicConstraints, critical: true, value: CaptureDER.sequence([])),
            ext(oid: OID.keyUsage, critical: true, value: CaptureDER.bitString(Data([0x80]), unusedBits: 7)),
            ext(oid: OID.extKeyUsage, critical: false, value: CaptureDER.sequence([CaptureDER.oid(OID.serverAuth)])),
            ext(oid: OID.subjectAltName, critical: false, value: CaptureDER.sequence([CaptureDER.tagged(0x82, Data(dnsName.utf8))])),
        ]
        return try sign(
            serial: randomSerial(),
            issuer: issuer,
            subject: encodeName(Subject(commonName: dnsName)),
            notBefore: now.addingTimeInterval(-86400),
            notAfter: now.addingTimeInterval(365 * 86400),
            spki: subjectPublicKeyInfo(leafKey),
            extensions: extensions,
            signer: signer
        )
    }

    static func pem(_ der: Data, label: String = "CERTIFICATE") -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }

    static func der(fromPEM pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }
        return Data(base64Encoded: lines.joined())
    }

    // MARK: - Internals

    private enum OID {
        static let ecPublicKey = "1.2.840.10045.2.1"
        static let prime256v1 = "1.2.840.10045.3.1.7"
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
        static let sha256WithRSA = "1.2.840.113549.1.1.11"
        static let commonName = "2.5.4.3"
        static let organization = "2.5.4.10"
        static let basicConstraints = "2.5.29.19"
        static let keyUsage = "2.5.29.15"
        static let extKeyUsage = "2.5.29.37"
        static let subjectAltName = "2.5.29.17"
        static let subjectKeyIdentifier = "2.5.29.14"
        static let authorityKeyIdentifier = "2.5.29.35"
        static let serverAuth = "1.3.6.1.5.5.7.3.1"
    }

    private static func sign(serial: Data, issuer: Data, subject: Data, notBefore: Date, notAfter: Date,
                             spki: Data, extensions: [Data], signer: Signer) throws -> Data {
        let algorithm = signer.algorithm
        let tbs = CaptureDER.sequence([
            CaptureDER.tagged(0xA0, CaptureDER.integer(Data([2]))),
            CaptureDER.integer(serial),
            algorithm,
            issuer,
            CaptureDER.sequence([CaptureDER.time(notBefore), CaptureDER.time(notAfter)]),
            subject,
            spki,
            CaptureDER.tagged(0xA3, CaptureDER.sequence(extensions)),
        ])
        let signature = try signer.sign(tbs)
        return CaptureDER.sequence([tbs, algorithm, CaptureDER.bitString(signature)])
    }

    private static func encodeName(_ subject: Subject) -> Data {
        var rdns: [Data] = []
        if let org = subject.organization {
            rdns.append(CaptureDER.set([CaptureDER.sequence([CaptureDER.oid(OID.organization), CaptureDER.utf8String(org)])]))
        }
        rdns.append(CaptureDER.set([CaptureDER.sequence([CaptureDER.oid(OID.commonName), CaptureDER.utf8String(subject.commonName)])]))
        return CaptureDER.sequence(rdns)
    }

    private static func subjectPublicKeyInfo(_ key: P256.Signing.PublicKey) -> Data {
        CaptureDER.sequence([
            CaptureDER.sequence([CaptureDER.oid(OID.ecPublicKey), CaptureDER.oid(OID.prime256v1)]),
            CaptureDER.bitString(key.x963Representation),
        ])
    }

    private static func keyIdentifier(_ key: P256.Signing.PublicKey) -> Data {
        Data(Insecure.SHA1.hash(data: key.x963Representation))
    }

    private static func ext(oid: String, critical: Bool, value: Data) -> Data {
        var parts = [CaptureDER.oid(oid)]
        if critical { parts.append(CaptureDER.boolean(true)) }
        parts.append(CaptureDER.octetString(value))
        return CaptureDER.sequence(parts)
    }

    private static func randomSerial() -> Data {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0x7f) | 0x40 // positive, no leading zero
        return Data(bytes)
    }

    /// Extracts the raw subject Name of a DER certificate (the leaf's issuer).
    static func issuerName(ofCertificate der: Data) -> Data? {
        var reader = CaptureDERReader(der)
        guard var cert = reader.readSequence(), var tbs = cert.readSequence() else { return nil }
        if tbs.peekTag == 0xA0 { _ = tbs.readElement() } // version
        _ = tbs.readElement()                             // serial
        _ = tbs.readElement()                             // signature algorithm
        _ = tbs.readElement()                             // issuer
        _ = tbs.readElement()                             // validity
        return tbs.readElement()                          // subject
    }
}

/// Tiny DER encoder.
nonisolated enum CaptureDER {
    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        out.append(length(value.count))
        out.append(value)
        return out
    }

    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func tagged(_ tag: UInt8, _ value: Data) -> Data { tlv(tag, value) }
    static func boolean(_ v: Bool) -> Data { tlv(0x01, Data([v ? 0xff : 0x00])) }
    static func null() -> Data { Data([0x05, 0x00]) }
    static func octetString(_ v: Data) -> Data { tlv(0x04, v) }
    static func utf8String(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }

    static func integer(_ magnitude: Data) -> Data {
        var bytes = [UInt8](magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data {
        tlv(0x03, Data([unusedBits]) + bytes)
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return tlv(0x06, Data()) }
        var out = Data([UInt8(parts[0] * 40 + parts[1])])
        for var v in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(v & 0x7f)]
            v >>= 7
            while v > 0 { chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0); v >>= 7 }
            out.append(contentsOf: chunk)
        }
        return tlv(0x06, out)
    }

    /// UTCTime before 2050, GeneralizedTime from 2050 (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 2000
        let rest = String(format: "%02d%02d%02d%02d%02dZ", c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if year < 2050 {
            return tlv(0x17, Data((String(format: "%02d", year % 100) + rest).utf8))
        }
        return tlv(0x18, Data((String(format: "%04d", year) + rest).utf8))
    }
}

/// Just enough DER reading to pull a Name out of a certificate.
nonisolated struct CaptureDERReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        self.offset = 0
    }

    var peekTag: UInt8? { offset < data.count ? data[offset] : nil }

    /// Returns the full TLV of the next element.
    mutating func readElement() -> Data? {
        guard let (start, end) = nextBounds() else { return nil }
        defer { offset = end }
        return data.subdata(in: start..<end)
    }

    /// Enters the next SEQUENCE.
    mutating func readSequence() -> CaptureDERReader? {
        guard peekTag == 0x30, let (start, end) = nextBounds() else { return nil }
        let headerLength = headerLength(at: start)
        offset = end
        return CaptureDERReader(data.subdata(in: (start + headerLength)..<end))
    }

    private func headerLength(at start: Int) -> Int {
        let first = data[start + 1]
        return first < 0x80 ? 2 : 2 + Int(first & 0x7f)
    }

    private func nextBounds() -> (Int, Int)? {
        guard offset + 2 <= data.count else { return nil }
        let first = data[offset + 1]
        var length = 0
        var header = 2
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard count <= 4, offset + 2 + count <= data.count else { return nil }
            for i in 0..<count { length = (length << 8) | Int(data[offset + 2 + i]) }
            header += count
        }
        let end = offset + header + length
        guard end <= data.count else { return nil }
        return (offset, end)
    }
}

#endif
