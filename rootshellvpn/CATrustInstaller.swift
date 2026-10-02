//
//  CATrustInstaller.swift
//  rootshellvpn (VPN host)
//
//  Installs the HTTP capture CA as a trusted SSL root for the current user.
//  Runs in the host because it is a native, unsandboxed macOS app; the
//  Catalyst app can't change trust settings itself.
//

import Foundation
import Security

nonisolated enum CATrustInstaller {
    /// Adds the certificate to the login keychain and marks it trusted for SSL.
    /// Blocks while macOS asks for the user's password. Returns an error message
    /// on failure.
    static func install(certificateDER: Data) -> String? {
        guard let cert = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            return "The certificate is not valid."
        }
        let addStatus = SecItemAdd(itemQuery(cert) as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            return message(addStatus)
        }
        let settings: [[String: Any]] = [[
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
        ]]
        let status = SecTrustSettingsSetTrustSettings(cert, .user, settings as CFArray)
        return status == errSecSuccess ? nil : message(status)
    }

    /// Removes the trust settings and the keychain item. Missing items are fine.
    static func remove(certificateDER: Data) -> String? {
        guard let cert = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            return "The certificate is not valid."
        }
        let trustStatus = SecTrustSettingsRemoveTrustSettings(cert, .user)
        if trustStatus != errSecSuccess && trustStatus != errSecItemNotFound {
            return message(trustStatus)
        }
        let deleteStatus = SecItemDelete(itemQuery(cert) as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            return message(deleteStatus)
        }
        return nil
    }

    private static func itemQuery(_ cert: SecCertificate) -> [String: Any] {
        [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert]
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Security error \(status)"
    }
}
