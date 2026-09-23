//
//  SFTPConnectionPool.swift
//  rootshell
//
//  App-wide SFTP connections keyed by endpoint, shared by every file manager
//  pane and transfer job so each host is authenticated once. A connection
//  closes after an idle delay once nothing retains it.
//

import Foundation

@MainActor
final class SFTPConnectionPool {
    static let shared = SFTPConnectionPool()

    enum Purpose {
        case browse
        case transfer
    }

    private var connections: [SFTPEndpoint: SFTPConnection] = [:]
    private var pending: [SFTPEndpoint: Task<SFTPConnection, Error>] = [:]
    private var retainCounts: [SFTPEndpoint: Int] = [:]
    private var idleClosers: [SFTPEndpoint: Task<Void, Never>] = [:]

    private init() {}

    /// A filesystem for `endpoint`, connecting (and prompting) if needed.
    func fileSystem(for endpoint: SFTPEndpoint, purpose: Purpose, prompts: FileManagerPrompts) async throws -> FileSystemEndpoint {
        if endpoint.isLocal {
            return FileSystemEndpoint(backend: .local(.current()))
        }
        let connection = try await connection(for: endpoint, prompts: prompts)
        switch purpose {
        case .browse: return connection.browseFileSystem
        case .transfer: return await connection.transferFileSystem()
        }
    }

    func connection(for endpoint: SFTPEndpoint, prompts: FileManagerPrompts) async throws -> SFTPConnection {
        if let existing = connections[endpoint] {
            if existing.isActive { return existing }
            connections[endpoint] = nil
            Task { await existing.close() }
        }
        if let task = pending[endpoint] {
            return try await task.value
        }
        let task = Task { try await SFTPConnectionFactory.open(endpoint, prompts: prompts) }
        pending[endpoint] = task
        defer { pending[endpoint] = nil }
        let connection = try await task.value
        connections[endpoint] = connection
        scheduleIdleCloseIfUnused(endpoint)
        return connection
    }

    /// Whether a live connection exists, without opening one.
    func isConnected(_ endpoint: SFTPEndpoint) -> Bool {
        endpoint.isLocal || connections[endpoint]?.isActive == true
    }

    func retain(_ endpoint: SFTPEndpoint) {
        guard !endpoint.isLocal else { return }
        retainCounts[endpoint, default: 0] += 1
        idleClosers.removeValue(forKey: endpoint)?.cancel()
    }

    func release(_ endpoint: SFTPEndpoint) {
        guard !endpoint.isLocal, let count = retainCounts[endpoint] else { return }
        if count <= 1 {
            retainCounts[endpoint] = nil
            scheduleIdleCloseIfUnused(endpoint)
        } else {
            retainCounts[endpoint] = count - 1
        }
    }

    /// Drops the connection now, e.g. after the user disconnects.
    func disconnect(_ endpoint: SFTPEndpoint) {
        pending.removeValue(forKey: endpoint)?.cancel()
        idleClosers.removeValue(forKey: endpoint)?.cancel()
        if let connection = connections.removeValue(forKey: endpoint) {
            Task { await connection.close() }
        }
    }

    private func scheduleIdleCloseIfUnused(_ endpoint: SFTPEndpoint) {
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
