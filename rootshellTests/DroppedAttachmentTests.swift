import XCTest
import UIKit
import UniformTypeIdentifiers

final class DroppedAttachmentTests: XCTestCase {
    private nonisolated final class WorkerCheckingImage: UIImage, @unchecked Sendable {
        var onDraw: (@Sendable () -> Void)?

        override func draw(in rect: CGRect) {
            XCTAssertFalse(Thread.isMainThread, "Drop image conversion must not block the main thread")
            super.draw(in: rect)
            onDraw?()
        }
    }

    /// Exercise providers that cannot vend Data and must be read as a file.
    private final class FileOnlyProvider: NSItemProvider, @unchecked Sendable {
        override func loadDataRepresentation(
            forTypeIdentifier typeIdentifier: String,
            completionHandler: @escaping @Sendable (Data?, Error?) -> Void
        ) -> Progress {
            completionHandler(nil, NSError(domain: "DroppedAttachmentTests", code: -1))
            return Progress(totalUnitCount: 0)
        }
    }

    private func imageData(width: CGFloat = 2) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 2), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 2))
        }.pngData()!
    }

    private func pdfData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 20, height: 20)).pdfData { context in
            context.beginPage()
            context.beginPage()
        }
    }

    private func provider(_ type: UTType, data: Data, delay: TimeInterval = 0) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(data, nil) }
            return nil
        }
        return provider
    }

    private func file(_ data: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func load(_ providers: [NSItemProvider]) async -> PasteAttachmentDetector.DropResult {
        await withCheckedContinuation { continuation in
            PasteAttachmentDetector.loadDropped(from: providers) { result in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: result)
            }
        }
    }

    func testImageConversionRunsOffMainAndDeliversOnMain() async throws {
        let drawn = expectation(description: "Thumbnail drawn on worker")
        let delivered = expectation(description: "Attachment delivered on main")
        let image = WorkerCheckingImage(cgImage: UIImage(data: imageData())!.cgImage!)
        image.onDraw = { drawn.fulfill() }
        PasteAttachmentDetector.prepareDroppedAttachment(.image(image)) { attachment in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(attachment?.uti, .png)
            XCTAssertNotNil(attachment?.thumbnail)
            delivered.fulfill()
        }
        await fulfillment(of: [drawn, delivered], timeout: 5)
    }

    func testImageDataAndUIImageObjectBecomeUniquePNGs() async throws {
        let data = imageData()
        let result = await load([provider(.png, data: data), NSItemProvider(object: UIImage(data: data)!)])
        XCTAssertTrue(result.containsAttachments)
        XCTAssertEqual(result.attachments.count, 2)
        XCTAssertEqual(Set(result.attachments.map(\.suggestedName)).count, 2)
        for attachment in result.attachments {
            XCTAssertEqual(attachment.uti, .png)
            XCTAssertNotNil(UIImage(data: attachment.data))
            XCTAssertNotNil(attachment.thumbnail)
        }
    }

    func testFileURLOnlyImageAndPDF() async throws {
        let pdf = pdfData()
        let imageURL = try file(imageData(), extension: "png")
        let pdfURL = try file(pdf, extension: "pdf")
        let result = await load([
            NSItemProvider(item: imageURL as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: pdfURL as NSURL, typeIdentifier: UTType.fileURL.identifier)
        ])
        XCTAssertTrue(result.containsAttachments)
        XCTAssertEqual(result.attachments.map(\.uti), [.png, .pdf])
        XCTAssertEqual(result.attachments.last?.data, pdf)
    }

    func testFinderNodeURLDataAndPathRepresentations() async throws {
        let url = try file(imageData(), extension: "png")
        let items: [NSSecureCoding] = [url as NSURL, url.dataRepresentation as NSData, url.path as NSString]
        for item in items {
            let result = await load([NSItemProvider(item: item, typeIdentifier: PasteAttachmentDetector.finderNodeType)])
            XCTAssertTrue(result.containsAttachments)
            XCTAssertEqual(result.attachments.count, 1)
        }
    }

    func testPDFWinsOverImagePreviewAndDuplicateRepresentations() async throws {
        let pdf = pdfData()
        let item = provider(.png, data: imageData())
        item.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            completion(pdf, nil)
            return nil
        }
        let result = await load([item])
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.attachments.first?.uti, .pdf)
        XCTAssertEqual(result.attachments.first?.data, pdf)
    }

    func testFileURLPDFWinsOverPreviewEvenWithoutAdvertisedPDF() async throws {
        let pdf = pdfData()
        let url = try file(pdf, extension: "pdf")
        let item = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let preview = imageData()
        item.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(preview, nil)
            return nil
        }
        let result = await load([item])
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.attachments.first?.data, pdf)
    }

    func testPromisedImageAndPDFWithoutFileURLs() async throws {
        let pdf = pdfData()
        let imageURL = try file(imageData(), extension: "png")
        let pdfURL = try file(pdf, extension: "pdf")
        let providers = [(UTType.png, imageURL), (UTType.pdf, pdfURL)].map { type, url in
            let item = FileOnlyProvider()
            item.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
            return item
        }
        let result = await load(providers)
        XCTAssertEqual(result.attachments.map(\.uti), [.png, .pdf])
        XCTAssertEqual(result.attachments.last?.data, pdf)
    }

    func testProviderOrderSurvivesOutOfOrderCompletion() async throws {
        let result = await load([
            provider(.png, data: imageData(width: 3), delay: 0.1),
            provider(.png, data: imageData(width: 5))
        ])
        XCTAssertEqual(result.attachments.compactMap { UIImage(data: $0.data)?.size.width }, [3, 5])
    }

    func testMissingFileAndCorruptImageRemainRecognizedWithoutPaths() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let result = await load([
            NSItemProvider(item: missing as NSURL, typeIdentifier: UTType.fileURL.identifier),
            provider(.png, data: Data("invalid image".utf8))
        ])
        XCTAssertTrue(result.containsAttachments)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testMissingFileFallsBackToImageRepresentation() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let item = NSItemProvider(item: missing as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let image = imageData()
        item.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(image, nil)
            return nil
        }
        let result = await load([item])
        XCTAssertTrue(result.containsAttachments)
        XCTAssertEqual(result.attachments.count, 1)
    }

    func testUntypedMissingURLDoesNotHideAnImageRepresentation() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let item = NSItemProvider(item: missing as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let image = imageData()
        item.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(image, nil)
            return nil
        }
        let result = await load([item])
        XCTAssertTrue(result.containsAttachments)
        XCTAssertEqual(result.attachments.count, 1)
    }

    func testMixedDropOnlyReturnsAttachmentsAndSkipsFailedItems() async throws {
        let url = try file(Data("text file".utf8), extension: "txt")
        let result = await load([
            NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier),
            provider(.png, data: Data()),
            provider(.pdf, data: pdfData()),
            NSItemProvider(object: "some text" as NSString)
        ])
        XCTAssertTrue(result.containsAttachments)
        XCTAssertEqual(result.attachments.map(\.uti), [.pdf])
    }

    func testOrdinaryFilesFoldersLinksAndTextAreNotAttachments() async throws {
        let url = try file(Data("text file".utf8), extension: "txt")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = [url, folder].map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        let preview = imageData()
        items[0].registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(preview, nil)
            return nil
        }
        let result = await load(items + [
            NSItemProvider(object: URL(string: "https://example.invalid/image.png")! as NSURL),
            NSItemProvider(object: "text" as NSString)
        ])
        XCTAssertFalse(result.containsAttachments)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testPasteStillUsesItsExistingAttachmentPreferences() async throws {
        let url = try file(imageData(), extension: "png")
        let fileOnly = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let attachments: [PasteAttachment] = await withCheckedContinuation { continuation in
            PasteAttachmentDetector.load(from: [fileOnly, provider(.pdf, data: pdfData())]) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(attachments.map(\.uti), [.pdf])
    }
}
