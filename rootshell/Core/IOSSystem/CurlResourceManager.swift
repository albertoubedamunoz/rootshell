import Foundation
import os

/// Manages curl resources (CA certificates) for the local shell
/// Keeps the user's home directory copy of the bundled cacert.pem CA certificate bundle current
/// Note: Curl TLS is only needed on iOS/iPadOS - Mac Catalyst uses system certificates
@MainActor
final class CurlResourceManager {
    static let shared = CurlResourceManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CurlResourceManager")

    private init() {}

    /// Sets up curl resources
    /// This copies the bundled cacert.pem to ~/.curl/cacert.pem for TLS/HTTPS support
    func setupResources() {
        #if targetEnvironment(macCatalyst)
        // Mac Catalyst uses system certificates - skip setup
        Self.logger.debug("Skipping curl resource setup on Mac Catalyst")
        return
        #else

        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Self.logger.error("Failed to get Documents directory")
            return
        }

        let curlDir = documentsURL.appendingPathComponent(".curl")

        // Create .curl directory if needed
        if !fileManager.fileExists(atPath: curlDir.path) {
            do {
                try fileManager.createDirectory(at: curlDir, withIntermediateDirectories: true)
                Self.logger.info("Created .curl directory at \(curlDir.path)")
            } catch {
                Self.logger.error("Failed to create .curl directory: \(error.localizedDescription)")
                return
            }
        }

        // Refresh ~/.curl/cacert.pem whenever it differs from the bundle, so app updates carry CA distrusts
        let cacertDest = curlDir.appendingPathComponent("cacert.pem")
        if let cacertSource = Bundle.main.url(forResource: "cacert", withExtension: "pem", subdirectory: "curl") {
            if !fileManager.contentsEqual(atPath: cacertSource.path, andPath: cacertDest.path) {
                do {
                    if fileManager.fileExists(atPath: cacertDest.path) {
                        try fileManager.removeItem(at: cacertDest)
                    }
                    try fileManager.copyItem(at: cacertSource, to: cacertDest)
                    Self.logger.info("Copied cacert.pem to \(cacertDest.path)")
                } catch {
                    Self.logger.error("Failed to copy cacert.pem: \(error.localizedDescription)")
                }
            }
        } else {
            Self.logger.warning("cacert.pem not found in bundle")
        }

        Self.logger.info("Curl resource setup complete")
        #endif
    }

    /// Returns the path to the CA certificate file, or nil if not set up
    var cacertPath: String? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = documentsURL.appendingPathComponent(".curl/cacert.pem").path
        return fileManager.fileExists(atPath: path) ? path : nil
        #endif
    }
}
