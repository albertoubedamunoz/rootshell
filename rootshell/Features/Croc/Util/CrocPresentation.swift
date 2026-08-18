#if !targetEnvironment(macCatalyst)

import CoreImage
import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum CrocPresentation {
    private static let machineIDKey = "crocMachineID"

    static func machineID() -> String {
#if canImport(UIKit)
        // `UIDevice.current.identifierForVendor` / `.name` are @MainActor
        // system APIs, but `machineID()` is called from CrocClient's off-main
        // network paths. A persisted random UUID gives a stable per-install
        // identifier with the same UUID-string shape, without touching the
        // main actor. UserDefaults is thread-safe; a first-call race just
        // means last-writer-wins on the initial value, stable thereafter.
        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: machineIDKey) {
            return cached
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: machineIDKey)
        return generated
#else
        Host.current().localizedName ?? UUID().uuidString
#endif
    }

    static func looksLikeIPv6Address(_ value: String) -> Bool {
        value.hasPrefix("[") || value.filter { $0 == ":" }.count > 1
    }

    static func copyToClipboard(
        code: String,
        flags: String,
        extended: Bool,
        quiet: Bool,
        output: (String) -> Void
    ) {
#if canImport(UIKit)
        let clipboardText: String
        if extended {
            let suffix = flags.isEmpty ? "" : flags + " "
            clipboardText = "CROC_SECRET=\"\(code)\" croc \(suffix)"
        } else {
            clipboardText = code
        }
        UIPasteboard.general.string = clipboardText
        guard !quiet else { return }
        output(extended ? "Command copied to clipboard!\r\n" : "Code copied to clipboard!\r\n")
#else
        _ = code
        _ = flags
        _ = extended
        _ = quiet
        _ = output
#endif
    }

    static func parseByteRate(_ value: String) -> Int64? {
        guard !value.isEmpty else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return nil }

        let multiplier: Int64
        let numberString: String
        switch last.lowercased() {
        case "k":
            multiplier = 1024
            numberString = String(trimmed.dropLast())
        case "m":
            multiplier = 1024 * 1024
            numberString = String(trimmed.dropLast())
        case "g":
            multiplier = 1024 * 1024 * 1024
            numberString = String(trimmed.dropLast())
        default:
            multiplier = 1
            numberString = trimmed
        }

        guard let base = Int64(numberString) else { return nil }
        return base * multiplier
    }

    static func renderQRCode(for string: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 8, y: 8)
        let transformed = image.transformed(by: scale)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent),
              let provider = cgImage.dataProvider,
              let pixelData = provider.data else {
            return nil
        }

        let data = CFDataGetBytePtr(pixelData)
        let bytesPerRow = cgImage.bytesPerRow
        let width = cgImage.width
        let height = cgImage.height
        var lines: [String] = []

        for y in stride(from: 0, to: height, by: 8) {
            var line = ""
            for x in stride(from: 0, to: width, by: 8) {
                let offset = y * bytesPerRow + x * 4
                let value = data?[offset] ?? 255
                line += value < 128 ? "██" : "  "
            }
            lines.append(line)
        }

        return lines.joined(separator: "\r\n")
    }
}

#endif
