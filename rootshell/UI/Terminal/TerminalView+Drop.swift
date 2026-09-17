//
//  TerminalView+Drop.swift
//  rootshell
//
//  File drag-and-drop support for terminal view.
//  Matches macOS Ghostty behavior: files/URLs are shell-escaped, plain text is inserted as-is.
//

import UIKit
import UniformTypeIdentifiers
import os
import GhosttyKit

// MARK: - UIDropInteractionDelegate

extension Ghostty.TerminalView: UIDropInteractionDelegate {

    /// Accepted drop types matching macOS Ghostty behavior:
    /// - File URLs: Paths are shell-escaped and inserted
    /// - URLs: Escaped as-is (useful for curl, wget, etc.)
    /// - Plain text: Inserted without escaping (for commands)
    /// - Images and PDFs: Uploaded wherever attachment paste supports SFTP
    static let acceptedDropTypes: [UTType] = [
        TabTransferCoordinator.dragUTType,
        .fileURL,
        .url,
        .plainText,
        .image,
        .pdf
    ]

    /// Finder node type used on Mac Catalyst when dragging files from Finder
    static let finderNodeType = PasteAttachmentDetector.finderNodeType

    // MARK: - Delegate Methods

    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        if session.items.contains(where: { $0.itemProvider.canLoadObject(ofClass: UIImage.self) }) {
            return true
        }
        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, accept drops with Finder nodes or standard types
        // Finder provides com.apple.finder.node instead of public.file-url
        return session.hasItemsConforming(toTypeIdentifiers: [Self.finderNodeType]) ||
               session.hasItemsConforming(toTypeIdentifiers: Self.acceptedDropTypes.map(\.identifier))
        #else
        // Accept if session contains any of our supported types
        return session.hasItemsConforming(toTypeIdentifiers: Self.acceptedDropTypes.map(\.identifier))
        #endif
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        if session.hasItemsConforming(toTypeIdentifiers: [TabTransferCoordinator.dragUTType.identifier]),
           TabTransferCoordinator.shared.canAcceptActiveDrag(in: windowId) {
            return UIDropProposal(operation: .move)
        }
        // Use .copy to show the proper drop cursor (green + icon)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        let itemProviders = session.items.map(\.itemProvider)

        // Log the offered types so drops that "do nothing" are diagnosable.
        let typeSummary = itemProviders
            .map { $0.registeredTypeIdentifiers.joined(separator: "|") }
            .joined(separator: " ; ")
        Ghostty.logger.info("performDrop offered types: \(typeSummary)")

        if session.hasItemsConforming(toTypeIdentifiers: [TabTransferCoordinator.dragUTType.identifier]),
           TabTransferCoordinator.shared.receiveActiveDrag(
               in: windowId,
               insertionIndex: tabTransferInsertionIndex(),
               groupOverride: tabTransferGroupOverride(),
               isDestinationWindowFocused: true
           ) {
            return
        }

        let sshConfig = attachmentUploadSSHConfig
        if sshConfig != nil || !canMaterializeAttachmentsLocally {
            PasteAttachmentDetector.loadDropped(from: itemProviders) { [weak self] result in
                guard let self, self.surface != nil else { return }
                if result.containsAttachments {
                    if let sshConfig {
                        if !result.attachments.isEmpty {
                            self.showAttachmentUploadSheet(attachments: result.attachments, sshConfig: sshConfig)
                        }
                    } else {
                        self.pasteUsableRemoteRepresentationOrShowAttachmentAlert(
                            from: itemProviders,
                            escapingURLs: true
                        )
                    }
                    // Recognized attachments own the whole drop, just as with
                    // paste. Never insert a failed attachment's local path.
                    return
                }
                self.insertDroppedProviders(itemProviders)
            }
        } else {
            insertDroppedProviders(itemProviders)
        }
    }

    /// Local drops prefer their original paths; remote drops arrive here only
    /// after attachment detection has ruled out images and PDFs.
    private func insertDroppedProviders(_ itemProviders: [NSItemProvider]) {
        let handleAttachments: () -> Void = { [weak self] in
            guard let self, self.canMaterializeAttachmentsLocally else { return }
            PasteAttachmentDetector.loadDropped(from: itemProviders) { [weak self] result in
                self?.materializeLocalPastedAttachments(result.attachments)
            }
        }

        // Try file URLs first
        let fileProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            loadFileURLs(from: fileProviders, fallback: handleAttachments)
            return
        }

        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, Finder provides com.apple.finder.node instead of public.file-url
        let finderProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(Self.finderNodeType) }
        if !finderProviders.isEmpty {
            loadFinderNodes(from: finderProviders, fallback: handleAttachments)
            return
        }
        #endif

        // Try regular URLs next
        let urlProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        if !urlProviders.isEmpty {
            loadURLs(from: urlProviders)
            return
        }

        if itemProviders.contains(where: {
            $0.canLoadObject(ofClass: UIImage.self)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }) {
            handleAttachments()
            return
        }

        // Fall back to plain text
        let textProviders = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        if !textProviders.isEmpty {
            loadPlainText(from: textProviders)
            return
        }
    }

    // MARK: - Item Loading

    private func tabTransferInsertionIndex() -> Int? {
        guard let model = TerminalWindowRegistry.tabsModel(for: windowId) else { return nil }
        return model.selectedTabID
            .flatMap { model.index(of: $0) }
            .map { $0 + 1 }
    }

    private func tabTransferGroupOverride() -> TabGroupID? {
        guard let model = TerminalWindowRegistry.tabsModel(for: windowId),
              model.isGroupedModeEnabled else { return nil }
        return model.activeGroupID
    }

    /// Load file URLs, escape paths, and insert into terminal.
    /// `fallback` runs on the main queue when no file URL could be resolved
    /// (e.g. a screenshot thumbnail that only offers a promised file).
    private func loadFileURLs(from providers: [NSItemProvider], fallback: (() -> Void)? = nil) {
        let group = DispatchGroup()
        var paths: [String] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()

            // Try the modern loadObject API first (works better on Mac Catalyst)
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    defer { group.leave() }
                    guard error == nil, let url = url else { return }

                    let escapedPath = Ghostty.Shell.escape(url.path)
                    lock.lock()
                    paths.append(escapedPath)
                    lock.unlock()
                }
            } else {
                // Fall back to loadItem for older API
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    guard error == nil else { return }

                    // Handle different representations
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let urlItem = item as? URL {
                        url = urlItem
                    } else if let string = item as? String {
                        url = URL(fileURLWithPath: string)
                    } else {
                        url = nil
                    }

                    if let url = url {
                        let escapedPath = Ghostty.Shell.escape(url.path)
                        lock.lock()
                        paths.append(escapedPath)
                        lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !paths.isEmpty else {
                // Nothing resolved (e.g. screenshot promised file) — try image data.
                fallback?()
                return
            }
            let content = paths.joined(separator: " ")
            self?.insertDroppedContent(content)
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Load Finder node items (Mac Catalyst specific)
    /// Finder provides com.apple.finder.node which contains the file URL.
    /// `fallback` runs on the main queue when no node could be resolved.
    private func loadFinderNodes(from providers: [NSItemProvider], fallback: (() -> Void)? = nil) {
        let group = DispatchGroup()
        var paths: [String] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()

            provider.loadItem(forTypeIdentifier: Self.finderNodeType, options: nil) { item, error in
                defer { group.leave() }
                guard error == nil else { return }

                // Extract URL from various representations
                let url: URL?
                if let urlItem = item as? URL {
                    url = urlItem
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                } else {
                    url = nil
                }

                if let url = url {
                    let escapedPath = Ghostty.Shell.escape(url.path)
                    lock.lock()
                    paths.append(escapedPath)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !paths.isEmpty else {
                // Nothing resolved — try image data (e.g. screenshot thumbnail).
                fallback?()
                return
            }
            let content = paths.joined(separator: " ")
            self?.insertDroppedContent(content)
        }
    }
    #endif

    /// Load URLs, escape them, and insert into terminal
    private func loadURLs(from providers: [NSItemProvider]) {
        // Just use the first URL
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
            guard error == nil else {
                Ghostty.logger.warning("Failed to load URL: \(error!.localizedDescription)")
                return
            }

            let urlString: String?
            if let url = item as? URL {
                urlString = url.absoluteString
            } else if let string = item as? String {
                urlString = string
            } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urlString = url.absoluteString
            } else {
                urlString = nil
            }

            if let urlString = urlString {
                let escaped = Ghostty.Shell.escape(urlString)
                DispatchQueue.main.async {
                    self?.insertDroppedContent(escaped)
                }
            }
        }
    }

    /// Load plain text and insert as-is (no escaping, for commands)
    private func loadPlainText(from providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, error in
            guard error == nil else {
                Ghostty.logger.warning("Failed to load text: \(error!.localizedDescription)")
                return
            }

            let text: String?
            if let string = item as? String {
                text = string
            } else if let data = item as? Data {
                text = String(data: data, encoding: .utf8)
            } else {
                text = nil
            }

            if let text = text {
                DispatchQueue.main.async {
                    // Plain text is not escaped - user may be pasting a command
                    self?.insertDroppedContent(text)
                }
            }
        }
    }

    // MARK: - Content Insertion

    /// Insert dropped content into the terminal
    private func insertDroppedContent(_ content: String) {
        guard insertPastedText(content, recordHistory: false) else {
            Ghostty.logger.warning("Dropped content but surface is nil or content is empty")
            return
        }
        Ghostty.logger.info("Dropped content inserted via surface text: \(content.prefix(50))...")
    }
}
