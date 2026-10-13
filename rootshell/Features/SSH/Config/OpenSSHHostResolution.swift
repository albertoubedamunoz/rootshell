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

    // MARK: - Host resolution

    /// OpenSSH takes the first value across all matching blocks in file order.
    /// Match only the requested alias, even if its Host line names other aliases.
    static func resolve(
        entry: OpenSSHHostEntry,
        entries: [OpenSSHHostEntry]
    ) -> OpenSSHHostEntry {
        guard let alias = entry.aliases.first else { return entry }
        var resolved = OpenSSHHostEntry(
            aliases: entry.aliases, hostName: nil, port: nil, user: nil,
            identityFiles: [], listsIdentityFileNone: false,
            proxyJump: nil, proxyCommand: nil, identityAgent: nil,
            isWildcard: entry.isWildcard, sourceFile: entry.sourceFile, sourceLine: entry.sourceLine
        )
        for block in entries {
            guard patternsApply(aliases: block.aliases, target: alias) else { continue }
            inherit(&resolved, from: block)
        }
        return resolved
    }

    /// Folds a later block into `resolved` the way ssh reads blocks in order:
    /// the first value of each directive wins, identities accumulate.
    private static func inherit(_ resolved: inout OpenSSHHostEntry, from block: OpenSSHHostEntry) {
        if resolved.hostName == nil { resolved.hostName = block.hostName }
        if resolved.port == nil { resolved.port = block.port }
        if resolved.user == nil { resolved.user = block.user }
        if block.proxyCommandFirst {
            takeProxyCommand(block.proxyCommand, into: &resolved)
            takeProxyJump(block.proxyJump, into: &resolved)
        } else {
            takeProxyJump(block.proxyJump, into: &resolved)
            takeProxyCommand(block.proxyCommand, into: &resolved)
        }
        if resolved.identityAgent == nil { resolved.identityAgent = block.identityAgent }
        for path in block.identityFiles where !resolved.identityFiles.contains(path) {
            resolved.identityFiles.append(path)
        }
        if block.listsIdentityFileNone { resolved.listsIdentityFileNone = true }
    }

    // Whichever of ProxyJump/ProxyCommand comes first wins (readconf.c parse_jump);
    // only `ProxyJump none` leaves a later ProxyCommand usable.
    private static func takeProxyJump(_ value: String?, into resolved: inout OpenSSHHostEntry) {
        guard let value, resolved.proxyJump == nil else { return }
        guard resolved.proxyCommand == nil || isNone(value) else { return }
        resolved.proxyJump = value
    }

    private static func takeProxyCommand(_ value: String?, into resolved: inout OpenSSHHostEntry) {
        guard let value, resolved.proxyCommand == nil else { return }
        guard resolved.proxyJump.map(isNone) ?? true else { return }
        resolved.proxyCommand = value
    }

    private static func isNone(_ value: String) -> Bool {
        value.caseInsensitiveCompare("none") == .orderedSame
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
    /// hops. Each hop alias is looked up against matching Host blocks in file
    /// order for its HostName/User/Port/IdentityFile; `user@`/`:port` in
    /// the ProxyJump value win. Like OpenSSH, the first hop's own ProxyJump is
    /// prepended (recursively); later hops are reached through the previous one.
    static func resolveJumpChain(
        for entry: OpenSSHHostEntry,
        entries: [OpenSSHHostEntry],
        defaultUsername: String,
        parseProxyCommand: (String) -> ProxyCommandHop? = { _ in nil },
        resolvePath: (String) -> String
    ) -> JumpChainResolution {
        let label = entry.aliases.first ?? "host"

        // `none` blocks later values of the directive, then means no proxy.
        if let proxyJump = entry.proxyJump, !proxyJump.isEmpty,
           !isNone(proxyJump) {
            do {
                let hops = try expandJumpChain(
                    proxyJump, visiting: entry.aliases.map { $0.lowercased() }, depth: 1,
                    entries: entries,
                    defaultUsername: defaultUsername, sourceFile: entry.sourceFile, resolvePath: resolvePath
                )
                return JumpChainResolution(hops: hops)
            } catch let error as JumpChainError {
                return JumpChainResolution(warning: "ProxyJump for \(label) skipped: \(error.message)")
            } catch {
                return JumpChainResolution(warning: "ProxyJump for \(label) skipped: \(error.localizedDescription)")
            }
        }

        if let proxyCommand = entry.proxyCommand, !proxyCommand.isEmpty,
           !isNone(proxyCommand) {
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
        entries: [OpenSSHHostEntry],
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
            let hopEntry = OpenSSHHostEntry(
                aliases: [alias], hostName: nil, port: nil, user: nil,
                identityFiles: [], listsIdentityFileNone: false,
                proxyJump: nil, proxyCommand: nil, identityAgent: nil,
                isWildcard: false, sourceFile: sourceFile, sourceLine: 0
            )
            let block = resolve(entry: hopEntry, entries: entries)

            // Later hops are reached through the previous one, which overrides
            // their own ProxyJump (OpenSSH passes -J for them).
            if index == 0, let nested = block.proxyJump, !nested.isEmpty,
               nested.caseInsensitiveCompare("none") != .orderedSame {
                hops += try expandJumpChain(
                    nested, visiting: visiting + [alias.lowercased()], depth: depth + 1,
                    entries: entries,
                    defaultUsername: defaultUsername, sourceFile: sourceFile, resolvePath: resolvePath
                )
            }

            let host = block.hostName ?? alias
            let port = spec.port ?? block.port ?? 22
            let username = spec.username ?? block.user ?? defaultUsername
            let identityPaths: [String]? = block.identityFiles.isEmpty && !block.listsIdentityFileNone
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
