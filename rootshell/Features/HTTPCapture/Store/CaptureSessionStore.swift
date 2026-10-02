//
//  CaptureSessionStore.swift
//  rootshell
//
//  Capture sessions on disk under <app group>/HTTPCapture/Sessions/<id>/.
//  iOS reads the extension's spool directly. On macOS the root system
//  extension's spool is mirrored into the same layout through provider
//  messages (`capture.read` / `capture.list`), so viewing code is identical.
//

#if !CHINA_BUILD

import Foundation
import os.log

@MainActor
@Observable
final class CaptureSessionStore {
    static let shared = CaptureSessionStore()

    nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HTTPCapture")
    nonisolated static let metaFileName = "session.json"

    private(set) var sessions: [CaptureSessionMeta] = []

    private init() {
        reload()
    }

    nonisolated static var root: URL? { CapturePaths.sessionsRoot() }

    nonisolated static func directory(for id: String) -> URL? {
        guard CapturePaths.isValidSessionID(id) else { return nil }
        return root?.appendingPathComponent(id, isDirectory: true)
    }

    /// Whether spool files come from the macOS system extension.
    nonisolated static var isMirrored: Bool {
        #if STANDALONE && targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    func reload() {
        guard let root = Self.root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            sessions = []
            return
        }
        sessions = names
            .filter(CapturePaths.isValidSessionID)
            .compactMap(Self.readMeta)
            .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated static func readMeta(_ id: String) -> CaptureSessionMeta? {
        guard let dir = directory(for: id),
              let data = try? Data(contentsOf: dir.appendingPathComponent(metaFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureSessionMeta.self, from: data)
    }

    func meta(_ id: String) -> CaptureSessionMeta? {
        sessions.first { $0.id == id }
    }

    func create(name: String, profileName: String?, recordPackets: Bool) throws -> CaptureSessionMeta {
        let meta = CaptureSessionMeta(
            id: UUID().uuidString,
            name: name,
            createdAt: Date(),
            profileName: profileName,
            recordedPackets: recordPackets
        )
        guard let dir = Self.directory(for: meta.id) else { throw CocoaError(.fileWriteUnknown) }
        try CapturePaths.ensureDirectory(dir)
        try write(meta)
        reload()
        return meta
    }

    func write(_ meta: CaptureSessionMeta) throws {
        guard let dir = Self.directory(for: meta.id) else { return }
        try CapturePaths.ensureDirectory(dir)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: dir.appendingPathComponent(Self.metaFileName), options: .atomic)
        if let index = sessions.firstIndex(where: { $0.id == meta.id }) {
            sessions[index] = meta
        } else {
            reload()
        }
    }

    func rename(_ id: String, to name: String) {
        guard var meta = meta(id) else { return }
        meta.name = name
        try? write(meta)
    }

    func markEnded(_ id: String) {
        guard var meta = meta(id), meta.endedAt == nil else { return }
        meta.endedAt = Date()
        meta.byteSize = Self.directorySize(id)
        try? write(meta)
    }

    /// Deletes a session. Anything still marked recording is refused (it may be
    /// what the engine writes to after an unconfirmed start or clear) unless the
    /// caller has confirmed with the engine that it isn't: `engineConfirmedIdle`.
    func delete(_ id: String, engineConfirmedIdle: Bool = false) async {
        guard id != CaptureController.shared.activeSessionID,
              engineConfirmedIdle || meta(id)?.isRecording != true,
              let dir = Self.directory(for: id) else { return }
        try? FileManager.default.removeItem(at: dir)
        if Self.isMirrored {
            _ = await CaptureController.shared.send(.delete, json: CaptureSessionRef(session: id))
        }
        reload()
    }

    /// Deletes every finished session; anything marked recording is kept.
    func deleteAll() async {
        for meta in sessions where !meta.isRecording {
            await delete(meta.id)
        }
    }

    /// Keeps the newest `limit` finished sessions.
    func enforceRetention(limit: Int) async {
        let finished = sessions.filter { !$0.isRecording && $0.id != CaptureController.shared.activeSessionID }
        guard finished.count > limit else { return }
        for meta in finished.sorted(by: { $0.createdAt > $1.createdAt }).dropFirst(limit) {
            await delete(meta.id)
        }
    }

    nonisolated static func directorySize(_ id: String) -> Int64 {
        guard let dir = directory(for: id),
              let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Mirroring (macOS)

    /// In-flight transfer per "session/path"; a second caller waits for it so
    /// two readers never fetch and append the same range.
    private var transfers: [String: Task<Int, Never>] = [:]

    /// Appends new bytes of a remote spool file to the local copy. Returns the
    /// number of bytes copied (0 when up to date or the tunnel is unreachable).
    @discardableResult
    func pullAppend(session: String, path: String) async -> Int {
        guard Self.isMirrored, CapturePaths.isValidRelativePath(path),
              let dir = Self.directory(for: session) else { return 0 }
        let key = "\(session)/\(path)"
        while let running = transfers[key] {
            _ = await running.value
            if transfers[key] == running { transfers[key] = nil }
        }
        let task = Task { await Self.copyRemainder(session: session, path: path, to: dir.appendingPathComponent(path)) }
        transfers[key] = task
        let copied = await task.value
        if transfers[key] == task { transfers[key] = nil }
        return copied
    }

    /// Copies remote bytes past the local file's end. Each chunk is written at
    /// the offset it was requested for, and only while the file is exactly that long.
    private static func copyRemainder(session: String, path: String, to local: URL) async -> Int {
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: local.path) {
            FileManager.default.createFile(atPath: local.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: local) else { return 0 }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd() else { return 0 }
        var copied = 0
        while true {
            let request = CaptureReadRequest(session: session, path: path, offset: Int64(offset), max: CapturePaths.readChunkLimit)
            guard let chunk = await CaptureController.shared.send(.read, json: request), !chunk.isEmpty else { break }
            do {
                guard try handle.seekToEnd() == offset else { break }
                try handle.write(contentsOf: chunk)
            } catch {
                logger.error("capture mirror write failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                break
            }
            offset += UInt64(chunk.count)
            copied += chunk.count
            if chunk.count < CapturePaths.readChunkLimit { break }
        }
        return copied
    }

    /// Copies every spool file of a finished session out of the system extension,
    /// then frees the extension's copy — only once every file is complete locally.
    func mirrorFully(session: String) async {
        guard Self.isMirrored, var meta = meta(session), meta.mirrored != true,
              let dir = Self.directory(for: session) else { return }
        guard let data = await CaptureController.shared.send(.list, json: CaptureSessionRef(session: session)),
              let files = try? JSONDecoder().decode([CaptureFileInfo].self, from: data) else { return }
        for file in files {
            await pullAppend(session: session, path: file.path)
        }
        let incomplete = files.filter { file in
            let size = (try? dir.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            return Int64(size) != file.size
        }
        guard incomplete.isEmpty else {
            Self.logger.error("capture mirror incomplete for \(session, privacy: .public): \(incomplete.count) file(s) short; keeping the extension's copy")
            return
        }
        meta.mirrored = true
        meta.byteSize = Self.directorySize(session)
        try? write(meta)
        _ = await CaptureController.shared.send(.delete, json: CaptureSessionRef(session: session))
    }

    /// Loads a body file, mirroring it first on macOS when it isn't local yet.
    func bodyData(session: String, path: String) async -> Data? {
        guard CapturePaths.isValidRelativePath(path), let dir = Self.directory(for: session) else { return nil }
        let url = dir.appendingPathComponent(path)
        if Self.isMirrored, meta(session)?.mirrored != true {
            _ = await pullAppend(session: session, path: path)
        }
        return try? Data(contentsOf: url)
    }
}

/// A live, incrementally loaded view of one session's transactions.
@MainActor
@Observable
final class CaptureSessionDocument {
    let sessionID: String
    private(set) var transactions: [CaptureTransaction] = []
    private(set) var stopReason: String?

    private var folder = CaptureIndexFolder()
    private var offset: UInt64 = 0
    private var pending = Data()
    private var pollTask: Task<Void, Never>?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func transaction(_ id: String?) -> CaptureTransaction? {
        guard let id else { return nil }
        return transactions.last { $0.id == id }
    }

    /// Polls the index until stopped: quickly while the session records, slowly
    /// otherwise (a cheap size check), so a stale "not recording" read can
    /// never end live updates.
    func startWatching() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let recording = CaptureSessionStore.shared.meta(self.sessionID)?.isRecording ?? true
                try? await Task.sleep(for: .milliseconds(recording ? 500 : 2000))
            }
        }
    }

    func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        if CaptureSessionStore.isMirrored {
            _ = await CaptureSessionStore.shared.pullAppend(session: sessionID, path: indexFileName)
        }
        guard let url = CaptureSessionStore.directory(for: sessionID)?.appendingPathComponent(indexFileName) else { return }
        let start = offset
        let chunk = await Task.detached(priority: .utility) { () -> Data? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: start)
            return try? handle.readToEnd()
        }.value
        guard let chunk, !chunk.isEmpty else { return }
        offset += UInt64(chunk.count)
        pending.append(chunk)
        // Only complete lines; a torn last line waits for the next read.
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        let decoder = JSONDecoder()
        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let event = try? decoder.decode(CaptureIndexEvent.self, from: Data(line)) {
                folder.apply(event)
            }
        }
        transactions = folder.transactions
        stopReason = folder.stopReason
    }

    private let indexFileName = "index.jsonl"

    func body(_ tx: CaptureTransaction, side: CaptureTransaction.Side) async -> Data? {
        guard let path = tx.bodyFile(side) else { return nil }
        return await CaptureSessionStore.shared.bodyData(session: sessionID, path: path)
    }

    func decodedBody(_ tx: CaptureTransaction, side: CaptureTransaction.Side) async -> (data: Data, decoded: Bool)? {
        guard let raw = await body(tx, side: side) else { return nil }
        let encoding = tx.headers(side).first("content-encoding")
        return await Task.detached(priority: .userInitiated) {
            CaptureBodyDecoder.decode(raw, contentEncoding: encoding)
        }.value
    }

    func webSocketFrames(_ tx: CaptureTransaction) async -> [CaptureWSFrame] {
        guard let data = await CaptureSessionStore.shared.bodyData(session: sessionID, path: "ws/\(tx.id).jsonl") else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).enumerated().compactMap { index, line in
            guard var frame = try? decoder.decode(CaptureWSFrame.self, from: Data(line)) else { return nil }
            frame.lineIndex = index
            return frame
        }
    }
}

#endif
