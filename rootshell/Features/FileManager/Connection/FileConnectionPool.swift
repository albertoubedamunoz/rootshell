//
//  FileConnectionPool.swift
//  rootshell
//
//  App-wide remote connections (SFTP sessions and storage clients) keyed by
//  endpoint, shared by every file manager pane and transfer job so each host
//  is authenticated once. A connection closes after an idle delay once
//  nothing retains it.
//

import Foundation

/// A live remote filesystem the pool can share and close.
nonisolated protocol FileConnection: AnyObject, Sendable {
    var isActive: Bool { get }
    /// For listings and small metadata calls.
    var browseFileSystem: FileSystemEndpoint { get }
    /// For bulk transfers; may be the browse filesystem.
    func transferFileSystem() async -> FileSystemEndpoint
    func close() async
}

@MainActor
final class FileConnectionPool {
    static let shared = FileConnectionPool()

    enum Purpose {
        case browse
        case transfer
    }

    private var connections: [FileEndpoint: any FileConnection] = [:]
    private var pending: [FileEndpoint: Task<any FileConnection, Error>] = [:]
    private var retainCounts: [FileEndpoint: Int] = [:]
    private var idleClosers: [FileEndpoint: Task<Void, Never>] = [:]

    private init() {}

    /// A filesystem for `endpoint`, connecting (and prompting) if needed.
    func fileSystem(for endpoint: FileEndpoint, purpose: Purpose, prompts: FileManagerPrompts) async throws -> FileSystemEndpoint {
        if endpoint.isLocal {
            return FileSystemEndpoint(backend: .local(.current()))
        }
        let connection = try await connection(for: endpoint, prompts: prompts)
        switch purpose {
        case .browse: return connection.browseFileSystem
        case .transfer: return await connection.transferFileSystem()
        }
    }

    private func connection(for endpoint: FileEndpoint, prompts: FileManagerPrompts) async throws -> any FileConnection {
        if let existing = connections[endpoint] {
            if existing.isActive { return existing }
            connections[endpoint] = nil
            Task { await existing.close() }
        }
        if let task = pending[endpoint] {
            return try await task.value
        }
        let task = Task<any FileConnection, Error> { try await Self.open(endpoint, prompts: prompts) }
        pending[endpoint] = task
        defer { pending[endpoint] = nil }
        let connection = try await task.value
        connections[endpoint] = connection
        scheduleIdleCloseIfUnused(endpoint)
        return connection
    }

    private static func open(_ endpoint: FileEndpoint, prompts: FileManagerPrompts) async throws -> any FileConnection {
        if case .storage(let id) = endpoint {
            guard let provider = StorageProviderStore.shared.provider(for: id) else {
                throw FileManagerConnectionError.storageProviderUnavailable
            }
            return try S3Connection(provider: provider)
        }
        return try await SFTPConnectionFactory.open(endpoint, prompts: prompts)
    }

    /// Whether a live connection exists, without opening one.
    func isConnected(_ endpoint: FileEndpoint) -> Bool {
        endpoint.isLocal || connections[endpoint]?.isActive == true
    }

    func retain(_ endpoint: FileEndpoint) {
        guard !endpoint.isLocal else { return }
        retainCounts[endpoint, default: 0] += 1
        idleClosers.removeValue(forKey: endpoint)?.cancel()
    }

    func release(_ endpoint: FileEndpoint) {
        guard !endpoint.isLocal, let count = retainCounts[endpoint] else { return }
        if count <= 1 {
            retainCounts[endpoint] = nil
            scheduleIdleCloseIfUnused(endpoint)
        } else {
            retainCounts[endpoint] = count - 1
        }
    }

    /// Drops the connection now, e.g. after the user disconnects or edits its settings.
    func disconnect(_ endpoint: FileEndpoint) {
        pending.removeValue(forKey: endpoint)?.cancel()
        idleClosers.removeValue(forKey: endpoint)?.cancel()
        if let connection = connections.removeValue(forKey: endpoint) {
            Task { await connection.close() }
        }
    }

    private func scheduleIdleCloseIfUnused(_ endpoint: FileEndpoint) {
        guard retainCounts[endpoint] == nil, connections[endpoint] != nil else { return }
        idleClosers[endpoint]?.cancel()
        let delay = SettingsStore.shared.value(Settings.Transfer.fileManagerIdleDisconnectMinutes)
        idleClosers[endpoint] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay) * 60))
            guard !Task.isCancelled, let self, self.retainCounts[endpoint] == nil else { return }
            self.idleClosers[endpoint] = nil
            self.disconnect(endpoint)
        }
    }
}
