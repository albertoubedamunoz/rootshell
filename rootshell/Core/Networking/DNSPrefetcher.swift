//
//  DNSPrefetcher.swift
//  rootshell
//
//  Warms the OS DNS cache for hostnames the user is likely to connect to,
//  so the in-session getaddrinfo call in SSHSession/CitadelSSHSession hits
//  the cache and returns immediately.
//

import Foundation

/// Non-main actor that deduplicates and rate-limits speculative DNS lookups.
/// All resolution work is dispatched via `Task.detached` so it never
/// serializes on the actor executor or runs on the main actor.
actor DNSPrefetcher {
    static let shared = DNSPrefetcher()

    private struct CompletedEntry {
        let at: Date
        let success: Bool
    }

    private static let positiveTTL: TimeInterval = 120
    private static let negativeTTL: TimeInterval = 15

    private var inflight: Set<String> = []
    private var completed: [String: CompletedEntry] = [:]

    private init() {}

    /// Warm the OS DNS cache for the given hostnames. Duplicates of in-flight
    /// or recently-completed hosts are skipped. Fire-and-forget: results
    /// are not returned; the side effect is a warm `getaddrinfo` cache.
    func prefetch(hostnames: [String]) {
        let now = Date()

        for raw in hostnames {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty else { continue }
            guard !inflight.contains(host) else { continue }
            if let entry = completed[host] {
                let ttl = entry.success ? Self.positiveTTL : Self.negativeTTL
                if now.timeIntervalSince(entry.at) < ttl { continue }
            }

            inflight.insert(host)

            Task.detached { [weak self] in
                let ip: String?
                if host.hasSuffix(".local") {
                    ip = await NetworkAddressUtils.resolveToRoutableIPv4(hostname: host)
                } else {
                    ip = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: host)
                }
                await self?.recordCompletion(host: host, success: ip != nil)
            }
        }
    }

    private func recordCompletion(host: String, success: Bool) {
        completed[host] = CompletedEntry(at: Date(), success: success)
        inflight.remove(host)
    }
}
