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

/// Loads non-text paste content suitable for SFTP upload.
enum PasteAttachmentDetector {

    /// Load paste-control item providers without reading UIPasteboard.general.
    /// Completion is always delivered on the main queue.
    static func load(from providers: [NSItemProvider], completion: @escaping ([PasteAttachment]) -> Void) {
        let candidates = providers.enumerated().filter {
            $0.element.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.element.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }
        guard !candidates.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var attachments = Array<PasteAttachment?>(repeating: nil, count: providers.count)

        for (index, provider) in candidates {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                    guard error == nil, let image = image as? UIImage else {
                        group.leave()
                        return
                    }
                    DispatchQueue.main.async {
                        let attachment = imageAttachment(from: image)
                        lock.lock()
                        attachments[index] = attachment
                        lock.unlock()
                        group.leave()
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                    guard error == nil, let data else {
                        group.leave()
                        return
                    }
                    DispatchQueue.main.async {
                        let attachment = PasteAttachment(
                            data: data,
                            suggestedName: generateName(extension: "pdf"),
                            uti: .pdf,
                            thumbnail: nil
                        )
                        lock.lock()
                        attachments[index] = attachment
                        lock.unlock()
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            completion(attachments.compactMap { $0 })
        }
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

    private static func generateName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let uniqueSuffix = UUID().uuidString.lowercased()
        return "paste-\(formatter.string(from: Date()))-\(uniqueSuffix).\(ext)"
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
