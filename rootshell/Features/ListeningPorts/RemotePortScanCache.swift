//
//  RemotePortScanCache.swift
//  rootshell
//
//  One scan per connection, not per pane. Every visible pane polls, and a
//  connection with four panes would otherwise run four `ss`/`lsof` probes in
//  the same instant and parse four identical answers. Callers that arrive
//  while a scan is in flight wait for that one, and a result younger than
//  `freshness` is served without touching the host at all.
//

import Foundation

@MainActor
final class RemotePortScanCache {
    static let shared = RemotePortScanCache()

    /// Panes poll every five seconds; anything younger than this is current.
    private let freshness: Duration = .seconds(4)
    /// Failed scans are not cached, so a dead link is retried by its caller.
    private struct Entry {
        let result: RemotePortScanResult
        let at: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]
    private var running: [String: Task<RemotePortScanResult, Error>] = [:]

    /// The scan for `key`, sharing an in-flight probe and a recent result.
    /// - Parameters:
    ///   - key: `user@host:port`, so panes on one connection share an answer.
    ///   - owner: the pane that actually holds the connection.
    func result(
        for key: String,
        command: String,
        nonce: String,
        owner: Ghostty.TerminalView
    ) async throws -> RemotePortScanResult {
        if let entry = entries[key], entry.at.duration(to: .now) < freshness {
            return entry.result
        }
        if let running = running[key] {
            return try await running.value
        }
        let task = Task { () throws -> RemotePortScanResult in
            let output = try await RemoteExecProbe.run(
                command,
                on: owner,
                timeout: 6,
                maxResponseBytes: 128 * 1024
            )
            return RemotePortScanParser.parse(output, nonce: nonce)
        }
        running[key] = task
        do {
            let result = try await task.value
            running[key] = nil
            entries[key] = Entry(result: result, at: .now)
            return result
        } catch {
            running[key] = nil
            throw error
        }
    }

    /// Drops what is remembered for `key`; a closed connection must not hand
    /// its ports to the next one that reuses the target.
    func forget(_ key: String) {
        entries[key] = nil
    }

    /// Test seam: forgets every remembered answer.
    func forgetAll() {
        entries.removeAll()
        running.removeAll()
    }
}
