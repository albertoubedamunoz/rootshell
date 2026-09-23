//
//  FileManagerDragDrop.swift
//  rootshell
//
//  Drag and drop for the file manager. Pane-to-pane drags carry the source
//  pane in the model, so they queue a normal transfer. Files dragged out are
//  offered as real files (remote ones download on demand); files dropped in
//  from Files or Finder are staged locally, then copied like any transfer.
//

import Foundation
import UniformTypeIdentifiers

enum FileManagerDragDrop {
    static let acceptedTypes: [UTType] = [.fileURL, .item]

    /// Drop staging under Caches; the providers' own copies vanish when their handler returns.
    static let stagingRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("FileManagerDrops", isDirectory: true)
    }()
}

extension FileManagerModel {
    struct DragPayload {
        let side: FilePaneModel.Side
        let endpoint: SFTPEndpoint
        let paths: [String]
        let startedAt = Date()
    }

    func beginDrag(of entries: [RFEntry], from side: FilePaneModel.Side) -> NSItemProvider {
        let pane = pane(side)
        dragPayload = DragPayload(side: side, endpoint: pane.endpoint, paths: entries.map(\.path))
        guard let first = entries.first else { return NSItemProvider() }

        let provider = NSItemProvider()
        provider.suggestedName = first.name
        if pane.endpoint.isLocal, !first.isDirectory {
            let url = URL(fileURLWithPath: LocalPathResolver.current().resolve(first.path))
            return NSItemProvider(contentsOf: url) ?? provider
        }
        guard !first.isDirectory else { return provider }
        let type = UTType(filenameExtension: first.fileExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await FileManagerPreviewCache.localURL(for: first, fs: try await pane.fileSystem(purpose: .transfer))
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    /// Queues a copy for a drop onto `side` (or into `directory` within it).
    func handleDrop(_ providers: [NSItemProvider], onto side: FilePaneModel.Side, directory: String?) -> Bool {
        // A drag abandoned mid-way leaves a payload behind; only trust it for the drop it names.
        if let payload = dragPayload,
           Date().timeIntervalSince(payload.startedAt) < 600,
           let first = payload.paths.first,
           providers.first?.suggestedName == FileTransferLogic.lastComponent(of: first) {
            dragPayload = nil
            let target = directory ?? pane(side).path
            // Dropping a folder into itself, or back onto its own listing, is a no-op.
            guard !(payload.side == side && directory == nil),
                  !payload.paths.contains(target) else { return false }
            activeSide = side
            receive(paths: payload.paths, from: payload.endpoint, into: side, directory: target)
            return true
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.item.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let staging = FileManagerDragDrop.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        Task {
            var staged: [String] = []
            for provider in fileProviders {
                if let path = await Self.stage(provider, into: staging) { staged.append(path) }
            }
            guard !staged.isEmpty else { return }
            activeSide = side
            receive(paths: staged, from: .local, into: side, directory: directory)
        }
        return true
    }

    /// Copies a dropped file or folder into `folder` while the provider still grants access.
    private static func stage(_ provider: NSItemProvider, into folder: URL) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination.path)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
