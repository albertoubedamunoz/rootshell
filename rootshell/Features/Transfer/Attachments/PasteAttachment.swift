//
//  PasteAttachment.swift
//  rootshell
//
//  Model and detection for non-text clipboard content (images, PDFs, files)
//  that can be uploaded to remote servers via SFTP during paste operations.
//

import UIKit
import UniformTypeIdentifiers
import os

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

/// Loads non-text paste content for SFTP upload or local path materialization.
enum PasteAttachmentDetector {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "rootshell",
        category: "PasteAttachment"
    )

    /// Load paste-control item providers without reading UIPasteboard.general.
    /// Completion is always delivered on the main queue.
    static func load(from providers: [NSItemProvider], completion: @escaping ([PasteAttachment]) -> Void) {
        let candidates = providers.enumerated().filter {
            $0.element.canLoadObject(ofClass: UIImage.self)
                || $0.element.hasItemConformingToTypeIdentifier(UTType.image.identifier)
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
            group.enter()
            loadAttachment(from: provider) { attachment in
                if let attachment {
                    lock.lock()
                    attachments[index] = attachment
                    lock.unlock()
                } else {
                    let types = provider.registeredTypeIdentifiers.joined(separator: "|")
                    logger.error("Failed to decode pasted attachment with types: \(types, privacy: .public)")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(attachments.compactMap { $0 })
        }
    }

    // MARK: - Private

    private static func loadAttachment(
        from provider: NSItemProvider,
        completion: @escaping (PasteAttachment?) -> Void
    ) {
        let hasImage = provider.canLoadObject(ofClass: UIImage.self)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        let hasPDF = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)

        // Prefer a real PDF over an image preview so multi-page Continuity
        // document scans keep every page.
        if hasPDF {
            loadPDF(from: provider) { attachment in
                if let attachment {
                    completion(attachment)
                } else if hasImage {
                    loadImage(from: provider, completion: completion)
                } else {
                    completion(nil)
                }
            }
            return
        }

        if hasImage {
            loadImage(from: provider, completion: completion)
        } else {
            completion(nil)
        }
    }

    private static func loadImage(
        from provider: NSItemProvider,
        completion: @escaping (PasteAttachment?) -> Void
    ) {
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            loadImageData(from: provider, completion: completion)
            return
        }

        _ = provider.loadObject(ofClass: UIImage.self) { image, error in
            DispatchQueue.main.async {
                if let image = image as? UIImage,
                   let attachment = imageAttachment(from: image) {
                    completion(attachment)
                    return
                }

                if let error {
                    logger.warning("UIImage provider load failed; trying data representation: \(error.localizedDescription, privacy: .public)")
                }
                loadImageData(from: provider, completion: completion)
            }
        }
    }

    private static func loadImageData(
        from provider: NSItemProvider,
        completion: @escaping (PasteAttachment?) -> Void
    ) {
        let imageTypes = provider.registeredTypeIdentifiers.filter {
            UTType($0)?.conforms(to: .image) == true
        }
        loadImageData(from: provider, typeIdentifiers: imageTypes, at: 0, completion: completion)
    }

    private static func loadImageData(
        from provider: NSItemProvider,
        typeIdentifiers: [String],
        at index: Int,
        completion: @escaping (PasteAttachment?) -> Void
    ) {
        guard index < typeIdentifiers.count else {
            completion(nil)
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifiers[index]) { data, error in
            DispatchQueue.main.async {
                if let data,
                   let image = UIImage(data: data),
                   let attachment = imageAttachment(from: image) {
                    completion(attachment)
                    return
                }

                if let error {
                    logger.warning("Image data provider load failed: \(error.localizedDescription, privacy: .public)")
                }
                loadImageData(
                    from: provider,
                    typeIdentifiers: typeIdentifiers,
                    at: index + 1,
                    completion: completion
                )
            }
        }
    }

    private static func loadPDF(
        from provider: NSItemProvider,
        completion: @escaping (PasteAttachment?) -> Void
    ) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) else {
            completion(nil)
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
            DispatchQueue.main.async {
                guard let data, !data.isEmpty else {
                    if let error {
                        logger.warning("PDF provider load failed: \(error.localizedDescription, privacy: .public)")
                    }
                    completion(nil)
                    return
                }
                completion(PasteAttachment(
                    data: data,
                    suggestedName: generateName(extension: "pdf"),
                    uti: .pdf,
                    thumbnail: nil
                ))
            }
        }
    }

    private static func imageAttachment(from image: UIImage) -> PasteAttachment? {
        let name = generateName(extension: "png")
        guard let data = image.pngData(), !data.isEmpty else { return nil }
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
