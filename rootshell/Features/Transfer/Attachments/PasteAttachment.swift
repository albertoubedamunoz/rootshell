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
    static let finderNodeType = "com.apple.finder.node"

    struct DropResult {
        let attachments: [PasteAttachment]
        // A failed attachment must not fall through to inserting its local path.
        let containsAttachments: Bool
    }

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

    /// Unlike paste, Finder/Files drops may advertise only a file URL or node.
    /// Keep this separate from paste so resolving file drops does not change
    /// clipboard representation preferences. All completions run on main.
    static func loadDropped(
        from providers: [NSItemProvider],
        completion: @escaping (DropResult) -> Void
    ) {
        let group = DispatchGroup()
        var attachments = Array<PasteAttachment?>(repeating: nil, count: providers.count)
        var containsAttachments = false
        for (index, provider) in providers.enumerated() {
            group.enter()
            loadDroppedAttachment(from: provider) { attachment, recognized in
                attachments[index] = attachment
                containsAttachments = containsAttachments || recognized
                if recognized && attachment == nil {
                    let types = provider.registeredTypeIdentifiers.joined(separator: "|")
                    logger.error("Failed to decode dropped attachment with types: \(types, privacy: .public)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(DropResult(
                attachments: attachments.compactMap { $0 },
                containsAttachments: containsAttachments
            ))
        }
    }

    private static func loadDroppedAttachment(
        from provider: NSItemProvider,
        completion: @escaping (PasteAttachment?, Bool) -> Void
    ) {
        let types = provider.registeredTypeIdentifiers.filter {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        }
        // A real document always wins over its thumbnail, even when the image
        // representation is registered first.
        let orderedTypes = types.filter { UTType($0)?.conforms(to: .pdf) == true }
            + types.filter { UTType($0)?.conforms(to: .image) == true }
        let hasImageObject = provider.canLoadObject(ofClass: UIImage.self)
        let urlTypes = [UTType.fileURL.identifier, finderNodeType, UTType.url.identifier]
            .filter { provider.hasItemConformingToTypeIdentifier($0) }

        loadDroppedFileURL(from: provider, types: urlTypes, at: 0) { file in
            // A known non-attachment file (including a folder) should keep its
            // path semantics even if the provider also offers a thumbnail.
            if let file, file.type == nil {
                completion(nil, false)
                return
            }
            let recognized = file?.type != nil || !types.isEmpty || hasImageObject
            let content = file.flatMap { file in
                file.type.map { DropContent.data(file.data, $0) }
            }
            prepareDroppedAttachment(content) { attachment in
                if let attachment {
                    completion(attachment, true)
                } else {
                    loadDroppedRepresentations(from: provider, types: orderedTypes, at: 0) { attachment in
                        if let attachment {
                            completion(attachment, true)
                        } else if hasImageObject {
                            // Do not use the paste loader here: its UIImage
                            // conversion runs on main along with paste handling.
                            _ = provider.loadObject(ofClass: UIImage.self) { image, _ in
                                prepareDroppedAttachment((image as? UIImage).map(DropContent.image)) {
                                    completion($0, recognized)
                                }
                            }
                        } else {
                            completion(nil, recognized)
                        }
                    }
                }
            }
        }
    }

    private struct DroppedFile: Sendable {
        let type: UTType?
        let data: Data?
    }

    /// Read in the provider callback, before a promised temporary file expires.
    /// Callers run this on a background queue, never on the UI thread.
    private nonisolated static func readDroppedFile(_ url: URL, hint: UTType? = nil) -> DroppedFile? {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return DroppedFile(type: nil, data: nil) }
        let candidates = [values?.contentType, UTType(filenameExtension: url.pathExtension), hint]
        guard let type = candidates.compactMap({ $0 }).first(where: {
            $0.conforms(to: .image) || $0.conforms(to: .pdf)
        }) else {
            // Missing or untyped promised URLs do not disqualify the provider's
            // actual image/PDF representations. Only a known other file does.
            guard let actualType = values?.contentType,
                  !actualType.isDynamic,
                  actualType != .data, actualType != .item, actualType != .content else { return nil }
            return DroppedFile(type: nil, data: nil)
        }
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: nil) { readableURL in
            data = try? Data(contentsOf: readableURL)
        }
        return DroppedFile(type: type, data: data)
    }

    private nonisolated static func droppedURL(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String {
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
            return URL(string: string)
        }
        return nil
    }

    private static func loadDroppedFileURL(
        from provider: NSItemProvider,
        types: [String],
        at index: Int,
        completion: @escaping (DroppedFile?) -> Void
    ) {
        guard index < types.count else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: types[index], options: nil) { item, _ in
            // Item-provider callbacks run off main. Read before returning so
            // temporary file representations remain available throughout I/O.
            let file = droppedURL(from: item).flatMap { readDroppedFile($0) }
            DispatchQueue.main.async {
                if let file {
                    completion(file)
                } else {
                    loadDroppedFileURL(from: provider, types: types, at: index + 1, completion: completion)
                }
            }
        }
    }

    private static func loadDroppedRepresentations(
        from provider: NSItemProvider,
        types: [String],
        at index: Int,
        completion: @escaping (PasteAttachment?) -> Void
    ) {
        guard index < types.count, let type = UTType(types[index]) else {
            completion(nil)
            return
        }
        // Keep the provider owned by main while conversion callbacks cross
        // queues; NSItemProvider itself is not Sendable.
        let loadNext: @MainActor @Sendable () -> Void = {
            loadDroppedRepresentations(from: provider, types: types, at: index + 1, completion: completion)
        }
        provider.loadDataRepresentation(forTypeIdentifier: types[index]) { data, _ in
            prepareDroppedAttachment(.data(data, type)) { attachment in
                if let attachment {
                    completion(attachment)
                    return
                }
                // Screenshot thumbnails and Files drags can provide a promised
                // file instead of data. Consume it before returning the callback.
                provider.loadFileRepresentation(forTypeIdentifier: types[index]) { url, _ in
                    let file = url.flatMap { readDroppedFile($0, hint: type) }
                    let content = file.flatMap { file in
                        file.type.map { DropContent.data(file.data, $0) }
                    }
                    prepareDroppedAttachment(content) { attachment in
                        if let attachment {
                            completion(attachment)
                        } else {
                            loadNext()
                        }
                    }
                }
            }
        }
    }

    nonisolated enum DropContent: Sendable {
        case data(Data?, UTType)
        case image(UIImage)
    }

    /// Decode, encode PNGs, and render thumbnails on a worker for every drop
    /// representation, including UIImage-only providers. Only delivery is main.
    nonisolated static func prepareDroppedAttachment(
        _ content: DropContent?,
        completion: @escaping @MainActor @Sendable (PasteAttachment?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let attachment = autoreleasepool {
                switch content {
                case .data(let data, let type):
                    return droppedAttachment(data: data, type: type)
                case .image(let image):
                    return imageAttachment(from: image)
                case nil:
                    return nil as PasteAttachment?
                }
            }
            DispatchQueue.main.async { completion(attachment) }
        }
    }

    private nonisolated static func droppedAttachment(data: Data?, type: UTType) -> PasteAttachment? {
        guard let data, !data.isEmpty else { return nil }
        if type.conforms(to: .pdf) {
            return PasteAttachment(data: data, suggestedName: generateName(extension: "pdf"), uti: .pdf, thumbnail: nil)
        }
        guard type.conforms(to: .image), let image = UIImage(data: data) else { return nil }
        return imageAttachment(from: image)
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

    private nonisolated static func imageAttachment(from image: UIImage) -> PasteAttachment? {
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

    private nonisolated static func generateName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let uniqueSuffix = UUID().uuidString.lowercased()
        return "paste-\(formatter.string(from: Date()))-\(uniqueSuffix).\(ext)"
    }

    private nonisolated static func generateThumbnail(from image: UIImage, maxSize: CGFloat = 120) -> UIImage? {
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
