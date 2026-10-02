//
//  CaptureCAManager.swift
//  rootshell
//
//  The per-install HTTP capture root CA: generation, keychain storage, trust
//  status, export (.cer / .pem / .p12 / .mobileconfig), and .p12 import.
//

#if !CHINA_BUILD

import CCryptoBoringSSL
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
@Observable
final class CaptureCAManager {
    static let shared = CaptureCAManager()

    enum TrustState: Equatable {
        case missing
        case checking
        case untrusted
        case trusted
    }

    enum CAError: LocalizedError {
        case keychainWriteFailed
        case noCertificate
        case unsupportedKey
        case importFailed(String)
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .keychainWriteFailed:
                String(localized: "Could not save the certificate to the keychain.", comment: "HTTP capture CA error")
            case .noCertificate:
                String(localized: "No capture certificate has been created yet.", comment: "HTTP capture CA error")
            case .unsupportedKey:
                String(localized: "Only P-256 and RSA certificate keys are supported.", comment: "HTTP capture CA error")
            case .importFailed(let detail):
                String(localized: "Could not import the certificate: \(detail)", comment: "HTTP capture CA error")
            case .exportFailed:
                String(localized: "Could not export the certificate.", comment: "HTTP capture CA error")
            }
        }
    }

    private(set) var certificateDER: Data?
    private(set) var trust: TrustState = .missing
    private(set) var commonName: String?
    private(set) var notAfter: Date?
    private(set) var fingerprint: String?

    private init() {
        load()
        // Trust is changed outside the app (Settings › Certificate Trust
        // Settings, Keychain Access), so re-check whenever we come back.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CaptureCAManager.shared.refreshTrust() }
        }
    }

    var hasCA: Bool { certificateDER != nil }

    var certificatePEM: String? {
        certificateDER.map { CaptureCertificateBuilder.pem($0) }
    }

    /// The engine needs both halves; on macOS they travel to the sysext.
    func keyMaterial() -> (certPEM: String, keyPEM: String)? {
        CaptureCAKeychain.read()
    }

    func load() {
        guard let stored = CaptureCAKeychain.read(),
              let der = CaptureCertificateBuilder.der(fromPEM: stored.certPEM) else {
            certificateDER = nil
            commonName = nil
            notAfter = nil
            fingerprint = nil
            trust = .missing
            return
        }
        apply(der: der)
    }

    private func apply(der: Data) {
        let changed = certificateDER != der
        certificateDER = der
        if let cert = SecCertificateCreateWithData(nil, der as CFData) {
            commonName = SecCertificateCopySubjectSummary(cert) as String?
        }
        notAfter = Self.notAfter(of: der)
        fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        // A loaded certificate's trust is unknown until evaluated; never show
        // the default (or a previous certificate's) state for it.
        if changed { trust = .checking }
        refreshTrust()
    }

    /// Creates a new CA if none exists.
    func ensureCA() throws {
        if hasCA { return }
        try generate()
    }

    func generate() throws {
        let key = P256.Signing.PrivateKey()
        let device = UIDevice.current.name
        let date = Date().formatted(.dateTime.year().month().day())
        let der = try CaptureCertificateBuilder.makeCA(
            subject: .init(commonName: "rootshell Capture CA (\(device) \(date))", organization: "rootshell"),
            key: key
        )
        guard CaptureCAKeychain.write(certPEM: CaptureCertificateBuilder.pem(der), keyPEM: key.pemRepresentation) else {
            throw CAError.keychainWriteFailed
        }
        apply(der: der)
    }

    /// Replaces the CA. The old one stays trusted by the OS until the user
    /// removes it (iOS) or we remove it through the host (macOS).
    func regenerate() async throws {
        #if STANDALONE && targetEnvironment(macCatalyst)
        if let old = certificateDER {
            try? await MacVPNController.shared.removeCATrust(certificateDER: old)
        }
        #endif
        CaptureCAKeychain.delete()
        certificateDER = nil
        try generate()
    }

    func delete() async {
        #if STANDALONE && targetEnvironment(macCatalyst)
        if let old = certificateDER {
            try? await MacVPNController.shared.removeCATrust(certificateDER: old)
        }
        #endif
        CaptureCAKeychain.delete()
        load()
    }

    // MARK: - Trust

    func refreshTrust() {
        guard let der = certificateDER, let material = CaptureCAKeychain.read() else {
            trust = .missing
            return
        }
        if trust != .trusted { trust = .checking }
        Task.detached(priority: .utility) {
            let trusted = Self.evaluateTrust(caDER: der, keyPEM: material.keyPEM)
            await MainActor.run {
                if CaptureCAManager.shared.certificateDER == der {
                    CaptureCAManager.shared.trust = trusted ? .trusted : .untrusted
                }
            }
        }
    }

    /// Mints a leaf for a reserved name and asks the OS whether it chains to a
    /// trusted root. This reflects iOS's "full trust" toggle and macOS trust settings.
    nonisolated static func evaluateTrust(caDER: Data, keyPEM: String) -> Bool {
        let host = "capture-check.rootshell.test"
        guard let signer = signer(forKeyPEM: keyPEM),
              let leafDER = try? CaptureCertificateBuilder.makeLeaf(
                  dnsName: host, leafKey: P256.Signing.PrivateKey().publicKey, caCertificate: caDER, signer: signer),
              let leaf = SecCertificateCreateWithData(nil, leafDER as CFData),
              let ca = SecCertificateCreateWithData(nil, caDER as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    nonisolated static func signer(forKeyPEM pem: String) -> CaptureCertificateBuilder.Signer? {
        if pem.contains("RSA PRIVATE KEY"), let der = CaptureCertificateBuilder.der(fromPEM: pem) {
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
            guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else { return nil }
            return .rsa(key)
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { return nil }
        return .p256(key)
    }

    #if STANDALONE && targetEnvironment(macCatalyst)
    /// macOS: add to the login keychain and trust for SSL via the VPN host.
    func installTrustOnMac() async throws {
        guard let der = certificateDER else { throw CAError.noCertificate }
        try await MacVPNController.shared.installCATrust(certificateDER: der)
        refreshTrust()
    }
    #endif

    // MARK: - Export

    func exportFile(_ kind: ExportKind, passphrase: String = "") throws -> URL {
        guard let der = certificateDER else { throw CAError.noCertificate }
        let data: Data
        switch kind {
        case .cer: data = der
        case .pem: data = Data(CaptureCertificateBuilder.pem(der).utf8)
        case .mobileconfig: data = mobileconfig() ?? Data()
        case .p12:
            guard let material = CaptureCAKeychain.read(),
                  let p12 = Self.makeP12(certDER: der, keyPEM: material.keyPEM, passphrase: passphrase,
                                         name: commonName ?? "rootshell Capture CA") else {
                throw CAError.exportFailed
            }
            data = p12
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rootshell-capture-ca.\(kind.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    enum ExportKind: String, CaseIterable, Identifiable {
        case cer, pem, p12, mobileconfig
        var id: String { rawValue }
        var fileExtension: String { rawValue }
        var title: String {
            switch self {
            case .cer: String(localized: "Certificate (.cer)", comment: "HTTP capture CA export format")
            case .pem: String(localized: "Certificate (.pem)", comment: "HTTP capture CA export format")
            case .p12: String(localized: "Certificate and Key (.p12)", comment: "HTTP capture CA export format")
            case .mobileconfig: String(localized: "Configuration Profile", comment: "HTTP capture CA export format")
            }
        }
    }

    /// Unsigned configuration profile with a com.apple.security.root payload.
    func mobileconfig() -> Data? {
        guard let der = certificateDER else { return nil }
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        func uuid(_ salt: String) -> String {
            let h = Array(SHA256.hash(data: Data((salt + digest).utf8)))
            var b = Array(h.prefix(16))
            b[6] = (b[6] & 0x0f) | 0x40
            b[8] = (b[8] & 0x3f) | 0x80
            return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
        }
        let name = commonName ?? "rootshell Capture CA"
        let profile: [String: Any] = [
            "PayloadContent": [[
                "PayloadCertificateFileName": "rootshell-capture-ca.cer",
                "PayloadContent": der,
                "PayloadDescription": "Root certificate used by rootshell HTTP capture",
                "PayloadDisplayName": name,
                "PayloadIdentifier": "com.rootshell.httpcapture.ca.\(digest.prefix(16))",
                "PayloadType": "com.apple.security.root",
                "PayloadUUID": uuid("payload"),
                "PayloadVersion": 1,
            ]],
            "PayloadDescription": "Lets rootshell decrypt HTTPS traffic for the hosts you choose.",
            "PayloadDisplayName": name,
            "PayloadIdentifier": "com.rootshell.httpcapture.profile.\(digest.prefix(16))",
            "PayloadOrganization": "rootshell",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": uuid("profile"),
            "PayloadVersion": 1,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    // MARK: - Import

    /// Imports a CA from a .p12 (e.g. exported from another device or tool).
    func importP12(_ data: Data, passphrase: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: passphrase] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw CAError.importFailed(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
        }
        let identity = identityRef as! SecIdentity
        var certRef: SecCertificate?
        var keyRef: SecKey?
        SecIdentityCopyCertificate(identity, &certRef)
        SecIdentityCopyPrivateKey(identity, &keyRef)
        guard let certRef, let keyRef,
              let keyData = SecKeyCopyExternalRepresentation(keyRef, nil) as Data?,
              let attrs = SecKeyCopyAttributes(keyRef) as? [String: Any],
              let type = attrs[kSecAttrKeyType as String] as? String else {
            throw CAError.importFailed(String(localized: "missing private key", comment: "HTTP capture CA import error detail"))
        }
        let keyPEM: String
        if type == (kSecAttrKeyTypeRSA as String) {
            keyPEM = CaptureCertificateBuilder.pem(keyData, label: "RSA PRIVATE KEY")
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String),
                  let key = try? P256.Signing.PrivateKey(x963Representation: keyData) {
            keyPEM = key.pemRepresentation
        } else {
            throw CAError.unsupportedKey
        }
        let der = SecCertificateCopyData(certRef) as Data
        guard CaptureCAKeychain.write(certPEM: CaptureCertificateBuilder.pem(der), keyPEM: keyPEM) else {
            throw CAError.keychainWriteFailed
        }
        apply(der: der)
    }

    // MARK: - Helpers

    nonisolated static func makeP12(certDER: Data, keyPEM: String, passphrase: String, name: String) -> Data? {
        guard let keyDER = CaptureCertificateBuilder.der(fromPEM: keyPEM) else { return nil }
        let x509 = certDER.withUnsafeBytes { raw -> OpaquePointer? in
            var p = raw.bindMemory(to: UInt8.self).baseAddress
            return CCryptoBoringSSL_d2i_X509(nil, &p, raw.count)
        }
        guard let x509 else { return nil }
        defer { CCryptoBoringSSL_X509_free(x509) }
        let pkey = keyDER.withUnsafeBytes { raw -> OpaquePointer? in
            var p = raw.bindMemory(to: UInt8.self).baseAddress
            return CCryptoBoringSSL_d2i_AutoPrivateKey(nil, &p, raw.count)
        }
        guard let pkey else { return nil }
        defer { CCryptoBoringSSL_EVP_PKEY_free(pkey) }
        // 3DES for key and certs: the widest importer support (Keychain, Firefox, Android).
        let pbeSHA1And3DES: Int32 = 146 // NID_pbe_WithSHA1And3_Key_TripleDES_CBC
        guard let p12 = CCryptoBoringSSL_PKCS12_create(passphrase, name, pkey, x509, nil, pbeSHA1And3DES, pbeSHA1And3DES, 0, 0, 0) else { return nil }
        defer { CCryptoBoringSSL_PKCS12_free(p12) }
        var out: UnsafeMutablePointer<UInt8>?
        let len = CCryptoBoringSSL_i2d_PKCS12(p12, &out)
        guard len > 0, let out else { return nil }
        defer { CCryptoBoringSSL_OPENSSL_free(out) }
        return Data(bytes: out, count: Int(len))
    }

    /// notAfter from the certificate's validity (UTCTime or GeneralizedTime).
    nonisolated static func notAfter(of der: Data) -> Date? {
        var reader = CaptureDERReader(der)
        guard var cert = reader.readSequence(), var tbs = cert.readSequence() else { return nil }
        if tbs.peekTag == 0xA0 { _ = tbs.readElement() }
        _ = tbs.readElement(); _ = tbs.readElement(); _ = tbs.readElement()
        guard var validity = tbs.readSequence() else { return nil }
        _ = validity.readElement()
        guard let element = validity.readElement(), element.count > 2 else { return nil }
        let text = String(decoding: element.dropFirst(2), as: UTF8.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = element.first == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return formatter.date(from: text)
    }
}

#endif
