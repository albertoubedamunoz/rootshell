#if DEBUG
import Foundation
import os

/// Manages joe text editor resources on iOS/iPadOS
/// Copies joerc configuration, ftyperc (file types), and syntax/color files to user's home directory on first launch
/// Note: Joe is only available on iOS/iPadOS, not Mac Catalyst
@MainActor
final class JoeResourceManager {
    static let shared = JoeResourceManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "JoeResourceManager")

    private init() {}

    /// Sets up joe resources if they don't exist
    /// This copies the bundled joerc, syntax/, and colors/ directories to the user's home
    func setupResources() {
        #if targetEnvironment(macCatalyst)
        // Joe is not available on Mac Catalyst - skip setup
        Self.logger.debug("Skipping joe resource setup on Mac Catalyst")
        return
        #else

        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Self.logger.error("Failed to get Documents directory")
            return
        }

        let joeHomeURL = documentsURL.appendingPathComponent(".joe")

        // Create .joe directory if needed
        if !fileManager.fileExists(atPath: joeHomeURL.path) {
            do {
                try fileManager.createDirectory(at: joeHomeURL, withIntermediateDirectories: true)
                Self.logger.info("Created .joe directory at \(joeHomeURL.path)")
            } catch {
                Self.logger.error("Failed to create .joe directory: \(error.localizedDescription)")
                return
            }
        }

        // Copy joerc to ~/.joerc if not present
        let joercDest = documentsURL.appendingPathComponent(".joerc")
        if !fileManager.fileExists(atPath: joercDest.path) {
            if let joercSource = Bundle.main.url(forResource: "joerc", withExtension: nil, subdirectory: "joe") {
                do {
                    try fileManager.copyItem(at: joercSource, to: joercDest)
                    Self.logger.info("Copied joerc to \(joercDest.path)")
                } catch {
                    Self.logger.error("Failed to copy joerc: \(error.localizedDescription)")
                }
            } else {
                Self.logger.warning("joerc not found in bundle")
            }
        }

        // Copy syntax directory to ~/.joe/syntax if not present
        let syntaxDest = joeHomeURL.appendingPathComponent("syntax")
        if !fileManager.fileExists(atPath: syntaxDest.path) {
            if let syntaxSource = Bundle.main.url(forResource: "syntax", withExtension: nil, subdirectory: "joe") {
                do {
                    try fileManager.copyItem(at: syntaxSource, to: syntaxDest)
                    Self.logger.info("Copied syntax directory to \(syntaxDest.path)")
                } catch {
                    Self.logger.error("Failed to copy syntax directory: \(error.localizedDescription)")
                }
            } else {
                Self.logger.warning("syntax directory not found in bundle")
            }
        }

        // Copy colors directory to ~/.joe/colors if not present
        let colorsDest = joeHomeURL.appendingPathComponent("colors")
        if !fileManager.fileExists(atPath: colorsDest.path) {
            if let colorsSource = Bundle.main.url(forResource: "colors", withExtension: nil, subdirectory: "joe") {
                do {
                    try fileManager.copyItem(at: colorsSource, to: colorsDest)
                    Self.logger.info("Copied colors directory to \(colorsDest.path)")
                } catch {
                    Self.logger.error("Failed to copy colors directory: \(error.localizedDescription)")
                }
            } else {
                Self.logger.warning("colors directory not found in bundle")
            }
        }

        // Copy ftyperc to ~/.joe/ftyperc if not present (required for syntax highlighting)
        let ftypercDest = joeHomeURL.appendingPathComponent("ftyperc")
        if !fileManager.fileExists(atPath: ftypercDest.path) {
            if let ftypercSource = Bundle.main.url(forResource: "ftyperc", withExtension: nil, subdirectory: "joe") {
                do {
                    try fileManager.copyItem(at: ftypercSource, to: ftypercDest)
                    Self.logger.info("Copied ftyperc to \(ftypercDest.path)")
                } catch {
                    Self.logger.error("Failed to copy ftyperc: \(error.localizedDescription)")
                }
            } else {
                Self.logger.warning("ftyperc not found in bundle")
            }
        }

        Self.logger.info("Joe resource setup complete")
        #endif
    }
}
#endif
