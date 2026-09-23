//
//  SSHConfig+Location.swift
//  rootshell
//
//  Whether two configs reach the same server account, so an identical path
//  on both is literally the same file.
//

import Foundation

extension SSHConfig {
    /// Errs conservative: it must be *certain* the two are the same before callers
    /// treat them as one filesystem.
    ///
    /// - Account scope matters: chrooted / user-scoped servers map the same path to
    ///   different files per user, so `username` (plus `port`/`jumpHost`) must match.
    /// - The same server is often reached under different host strings — letter case
    ///   (DNS is case-insensitive) or a `.local` name vs. its resolved/cached IP —
    ///   so we match on any shared host candidate rather than the raw string.
    ///
    /// Limitation: arbitrary aliases that share no host/IP candidate (e.g. a CNAME
    /// or `/etc/hosts` entry with a wholly different name and no cached IP) can't be
    /// proven equal statically and are treated as different.
    func reachesSameAccount(as other: SSHConfig) -> Bool {
        guard username == other.username,
              port == other.port,
              Self.sameJumpLocation(jumpHost, other.jumpHost) else { return false }
        return !hostCandidates.isDisjoint(with: other.hostCandidates)
    }

    /// Lower-cased host plus any cached IP — the set of strings that may name this
    /// server. A non-empty intersection means the same machine.
    private var hostCandidates: Set<String> {
        var set: Set<String> = [host.lowercased()]
        if let ip = cachedIP, !ip.isEmpty { set.insert(ip.lowercased()) }
        return set
    }

    /// Whether two routes traverse the same jump host *location*. Compares only the
    /// location-defining fields (host/port/username) — auth details like authMethod,
    /// fallback keys, and key-resolution hints don't change which server is reached,
    /// so including them would wrongly split the same route into "different".
    private static func sameJumpLocation(_ a: JumpHostConfig?, _ b: JumpHostConfig?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a.host.lowercased() == b.host.lowercased()
                && a.port == b.port
                && a.username == b.username
        default:
            return false
        }
    }
}
