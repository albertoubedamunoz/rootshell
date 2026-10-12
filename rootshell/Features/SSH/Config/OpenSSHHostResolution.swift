//
//  OpenSSHHostResolution.swift
//  rootshell
//
//  Pure ~/.ssh/config resolution shared by the OpenSSH importer: wildcard
//  inheritance and ProxyJump chain expansion. No app state, so tests compile it.
//

import Foundation

enum OpenSSHHostResolution {
    /// A ProxyCommand reduced to a single hop.
    struct ProxyCommandHop {
        var host: String
        var port: Int
        var username: String?
    }

    // MARK: - Wildcard inheritance

    /// Apply matching wildcard blocks to fill in unset directives on a concrete
    /// entry. First-match-wins per directive matches OpenSSH semantics for
    /// directives like `HostName`, `User`, `Port`, etc.
    static func resolveWithWildcards(
        entry: OpenSSHHostEntry,
        wildcards: [OpenSSHHostEntry]
    ) -> OpenSSHHostEntry {
        var resolved = entry
        for wildcard in wildcards {
            // A wildcard block applies to this entry if any of the entry's
            // aliases satisfies the block's full pattern list (positive +
            // negation, OpenSSH semantics).
            let matches = resolved.aliases.contains { alias in
                patternsApply(aliases: wildcard.aliases, target: alias)
            }
            guard matches else { continue }
            inherit(&resolved, from: wildcard)
        }
        return resolved
    }

    /// Folds a later block into `resolved` the way ssh reads blocks in order:
    /// the first value of each directive wins, identities accumulate.
    private static func inherit(_ resolved: inout OpenSSHHostEntry, from block: OpenSSHHostEntry) {
        if resolved.hostName == nil { resolved.hostName = block.hostName }
        if resolved.port == nil { resolved.port = block.port }
        if resolved.user == nil { resolved.user = block.user }
        if resolved.proxyJump == nil { resolved.proxyJump = block.proxyJump }
        if resolved.proxyCommand == nil { resolved.proxyCommand = block.proxyCommand }
        // IdentityFile semantics across blocks:
        // - A block with `IdentityFile none` discards the cumulative list
        //   (earlier blocks) and then appends its own remaining identities.
        //   The clear propagates so later blocks cannot re-add identities.
        // - A block without a clear contributes its identities only if no
        //   prior block has cleared.
        if block.identityFilesCleared {
            resolved.identityFiles.removeAll()
            resolved.identityFilesCleared = true
            for path in block.identityFiles where !resolved.identityFiles.contains(path) {
                resolved.identityFiles.append(path)
            }
        } else if !resolved.identityFilesCleared {
            for path in block.identityFiles where !resolved.identityFiles.contains(path) {
                resolved.identityFiles.append(path)
            }
        }
    }

    /// True if a Host block's pattern list applies to `target` under OpenSSH
    /// semantics: at least one positive pattern matches AND no negated pattern
    /// matches. A block of only negations never matches (matches OpenSSH).
    private static func patternsApply(aliases: [String], target: String) -> Bool {
        var sawPositiveMatch = false
        for pattern in aliases {
            if pattern.hasPrefix("!") {
                let body = String(pattern.dropFirst())
                if fnmatch(pattern: body, name: target) { return false }
            } else if fnmatch(pattern: pattern, name: target) {
                sawPositiveMatch = true
            }
        }
        return sawPositiveMatch
    }

    private static func fnmatch(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var pi = 0
        var ni = 0
        var starPi = -1
        var starNi = -1
        while ni < n.count {
            if pi < p.count, p[pi] == "?" {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starNi = ni
                pi += 1
            } else if pi < p.count, p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starNi += 1
                ni = starNi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Jump host resolution

    /// One resolved ProxyJump hop before key plans exist.
    struct ResolvedJumpHop: Hashable {
        var host: String
        var port: Int
        var username: String
        /// Absolute identity paths from the hop's own Host block; nil inherits the target's.
        var identityPaths: [String]?
        var display: String
    }

    struct JumpChainResolution: Hashable {
        var hops: [ResolvedJumpHop] = []
        var warning: String?
    }

    /// Longest chain a hop's own ProxyJump may prepend before we give up.
    static let maxJumpDepth = 8

    /// Resolves a wildcard-resolved entry's `ProxyJump` (or `ProxyCommand`) into
    /// hops. Each hop alias is looked up against the concrete Host blocks (then
    /// wildcards) for its HostName/User/Port/IdentityFile; `user@`/`:port` in
    /// the ProxyJump value win. Like OpenSSH, the first hop's own ProxyJump is
    /// prepended (recursively); later hops are reached through the previous one.
    static func resolveJumpChain(
        for entry: OpenSSHHostEntry,
        concretes: [OpenSSHHostEntry],
        wildcards: [OpenSSHHostEntry],
        defaultUsername: String,
        parseProxyCommand: (String) -> ProxyCommandHop? = { _ in nil },
        resolvePath: (String) -> String
    ) -> JumpChainResolution {
        let label = entry.aliases.first ?? "host"

        if let proxyJump = entry.proxyJump, !proxyJump.isEmpty {
            // ProxyJump none is OpenSSH's "clear inherited proxy" sentinel.
            if proxyJump.caseInsensitiveCompare("none") == .orderedSame {
                return JumpChainResolution()
            }
            do {
                let hops = try expandJumpChain(
                    proxyJump, visiting: entry.aliases.map { $0.lowercased() }, depth: 1,
                    concretes: concretes, wildcards: wildcards,
                    defaultUsername: defaultUsername, sourceFile: entry.sourceFile, resolvePath: resolvePath
                )
                return JumpChainResolution(hops: hops)
            } catch let error as JumpChainError {
                return JumpChainResolution(warning: "ProxyJump for \(label) skipped: \(error.message)")
            } catch {
                return JumpChainResolution(warning: "ProxyJump for \(label) skipped: \(error.localizedDescription)")
            }
        }

        if let proxyCommand = entry.proxyCommand, !proxyCommand.isEmpty {
            if let parsed = parseProxyCommand(proxyCommand) {
                let username = parsed.username ?? defaultUsername
                return JumpChainResolution(hops: [ResolvedJumpHop(
                    host: parsed.host,
                    port: parsed.port,
                    username: username,
                    identityPaths: nil,
                    display: hopDisplay(username: username, host: parsed.host, port: parsed.port)
                )])
            }
            return JumpChainResolution(warning: "Unrecognized ProxyCommand for \(label): \(proxyCommand)")
        }

        return JumpChainResolution()
    }

    private struct JumpChainError: Error {
        let message: String
    }

    private static func expandJumpChain(
        _ proxyJump: String,
        visiting: [String],
        depth: Int,
        concretes: [OpenSSHHostEntry],
        wildcards: [OpenSSHHostEntry],
        defaultUsername: String,
        sourceFile: URL,
        resolvePath: (String) -> String
    ) throws -> [ResolvedJumpHop] {
        guard depth <= maxJumpDepth else {
            throw JumpChainError(message: "more than \(maxJumpDepth) nested jump hosts")
        }
        guard let specs = ProxyJumpSpec.parseList(proxyJump) else {
            throw JumpChainError(message: "unrecognized value \"\(proxyJump)\"")
        }

        var hops: [ResolvedJumpHop] = []
        for (index, spec) in specs.enumerated() {
            let alias = spec.host
            guard !visiting.contains(alias.lowercased()) else {
                throw JumpChainError(message: "jump host \(alias) loops back to itself")
            }
            // Every block naming the hop applies, in file order; wildcards match only
            // the name ssh would look up, not a block's other aliases.
            var hopEntry = OpenSSHHostEntry(
                aliases: [alias], hostName: nil, port: nil, user: nil,
                identityFiles: [], identityFilesCleared: false,
                proxyJump: nil, proxyCommand: nil, identityAgent: nil,
                isWildcard: false, sourceFile: sourceFile, sourceLine: 0
            )
            for block in concretes where block.aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                inherit(&hopEntry, from: block)
            }
            let block = resolveWithWildcards(entry: hopEntry, wildcards: wildcards)

            // Later hops are reached through the previous one, which overrides
            // their own ProxyJump (OpenSSH passes -J for them).
            if index == 0, let nested = block.proxyJump, !nested.isEmpty,
               nested.caseInsensitiveCompare("none") != .orderedSame {
                hops += try expandJumpChain(
                    nested, visiting: visiting + [alias.lowercased()], depth: depth + 1,
                    concretes: concretes, wildcards: wildcards,
                    defaultUsername: defaultUsername, sourceFile: sourceFile, resolvePath: resolvePath
                )
            }

            let host = block.hostName ?? alias
            let port = spec.port ?? block.port ?? 22
            let username = spec.username ?? block.user ?? defaultUsername
            let identityPaths: [String]? = block.identityFiles.isEmpty && !block.identityFilesCleared
                ? nil
                : block.identityFiles.map(resolvePath)
            hops.append(ResolvedJumpHop(
                host: host,
                port: port,
                username: username,
                identityPaths: identityPaths,
                display: hopDisplay(username: username, host: host, port: port)
            ))
        }
        guard hops.count <= maxJumpDepth else {
            throw JumpChainError(message: "more than \(maxJumpDepth) jump hosts")
        }
        return hops
    }

    private static func hopDisplay(username: String, host: String, port: Int) -> String {
        port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }
}
