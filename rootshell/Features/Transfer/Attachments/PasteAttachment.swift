//
//  PasteAttachment.swift
//  rootshell
//
//  Model and detection for non-text clipboard content (images, PDFs, files)
//  that can be uploaded to remote servers via SFTP during paste operations.
//

import UIKit
import UniformTypeIdentifiers

/// Represents a non-text attachment detected on the clipboard
struct PasteAttachment: Sendable {
    let data: Data
    let suggestedName: String
    let uti: UTType
    let thumbnail: UIImage?

    var fileExtension: String {
        uti.preferredFilenameExtension ?? "bin"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

/// Result of inspecting the clipboard for paste content
enum PasteContent: Sendable {
    case empty
    case textOnly
    case attachments([PasteAttachment])
}

/// Inspects UIPasteboard for non-text content suitable for SFTP upload
enum PasteAttachmentDetector {

    /// Inspect the general pasteboard and classify its content
    @MainActor
    static func detect() -> PasteContent {
        let pb = UIPasteboard.general

        // Check for images first (most common paste-from-Photos flow)
        if pb.hasImages, let image = pb.image {
            let attachment = imageAttachment(from: image)
            return .attachments([attachment])
        }

        // Check for typed item data (PDFs, etc.)
        var attachments: [PasteAttachment] = []
        for item in pb.items {
            if let att = extractAttachment(from: item) {
                attachments.append(att)
            }
        }
        if !attachments.isEmpty {
            return .attachments(attachments)
        }

        // Check for text content
        if pb.hasStrings || pb.hasURLs {
            return .textOnly
        }

        return .empty
    }

    // MARK: - Private

    private static func imageAttachment(from image: UIImage) -> PasteAttachment {
        let name = generateName(extension: "png")
        let data = image.pngData() ?? Data()
        let thumbnail = generateThumbnail(from: image)
        return PasteAttachment(
            data: data,
            suggestedName: name,
            uti: .png,
            thumbnail: thumbnail
        )
    }

    private static func extractAttachment(from item: [String: Any]) -> PasteAttachment? {
        // PDF
        if let data = item[UTType.pdf.identifier] as? Data {
            return PasteAttachment(
                data: data,
                suggestedName: generateName(extension: "pdf"),
                uti: .pdf,
                thumbnail: nil
            )
        }
        // JPEG
        if let data = item[UTType.jpeg.identifier] as? Data {
            let image = UIImage(data: data)
            return PasteAttachment(
                data: data,
                suggestedName: generateName(extension: "jpg"),
                uti: .jpeg,
                thumbnail: image.flatMap { generateThumbnail(from: $0) }
            )
        }
        // PNG
        if let data = item[UTType.png.identifier] as? Data {
            let image = UIImage(data: data)
            return PasteAttachment(
                data: data,
                suggestedName: generateName(extension: "png"),
                uti: .png,
                thumbnail: image.flatMap { generateThumbnail(from: $0) }
            )
        }
        return nil
    }

    private static func generateName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "paste-\(formatter.string(from: Date())).\(ext)"
    }

    private static func generateThumbnail(from image: UIImage, maxSize: CGFloat = 120) -> UIImage? {
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let size = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
