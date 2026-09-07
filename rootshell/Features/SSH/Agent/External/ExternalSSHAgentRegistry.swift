//
//  ExternalSSHAgentRegistry.swift
//  rootshell (Catalyst, Standalone)
//
//  Persisted list of external OpenSSH agents the user has configured, plus
//  discovery of candidates: the 1Password agent's well-known socket,
//  IdentityAgent directives in ~/.ssh/config, and $SSH_AUTH_SOCK. Nothing
//  secret is stored — an agent entry is just a display name and socket path.
//

#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation
import os.log

nonisolated struct ExternalSSHAgent: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case manual
        case sshConfig
        case onePassword
        case environment

        var label: String {
            switch self {
            case .manual: return String(localized: "Manual", comment: "External agent source: manually entered")
            case .sshConfig: return String(localized: "ssh config", comment: "External agent source: ~/.ssh/config IdentityAgent")
            case .onePassword: return "1Password"
            case .environment: return "$SSH_AUTH_SOCK"
            }
        }
    }

    let id: UUID
    var name: String
    var socketPath: String
    var source: Source
    var addedDate: Date

    init(id: UUID = UUID(), name: String, socketPath: String, source: Source, addedDate: Date = Date()) {
        self.id = id
        self.name = name
        self.socketPath = socketPath
        self.source = source
        self.addedDate = addedDate
    }
}

@MainActor
@Observable
final class ExternalSSHAgentRegistry {
    static let shared = ExternalSSHAgentRegistry()

    private static let logger = Logger(subsystem: "com.rootshell", category: "ExternalSSHAgentRegistry")
    private static let defaultsKey = "externalSSHAgents"

    nonisolated static let onePasswordSocketPath =
        NSHomeDirectory() + "/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    private(set) var agents: [ExternalSSHAgent] = []
    /// Transient probe results, refreshed on demand. Missing key = not probed yet.
    private(set) var reachability: [UUID: Bool] = [:]

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([ExternalSSHAgent].self, from: data) {
            agents = stored
        }
    }

    // MARK: - CRUD

    func add(_ agent: ExternalSSHAgent) {
        guard !agents.contains(where: { $0.socketPath == agent.socketPath }) else { return }
        agents.append(agent)
        persist()
    }

    func remove(id: UUID) {
        agents.removeAll { $0.id == id }
        reachability[id] = nil
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].name = name
        persist()
    }

    func updateSocketPath(id: UUID, to path: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].socketPath = path
        reachability[id] = nil
        persist()
    }

    func agent(id: UUID) -> ExternalSSHAgent? {
        agents.first { $0.id == id }
    }

    /// Current socket path for an agent-backed key. Prefers the live registry
    /// entry (the user may have re-pointed the agent) over the path snapshot
    /// stored on the key.
    func socketPath(forAgentID id: UUID) -> String? {
        agent(id: id).map { liveSocketPath(for: $0) }
    }

    /// Resolve a usable agent socket for an imported external-agent key.
    ///
    /// macOS launchd `$SSH_AUTH_SOCK` paths rotate across logins. Keys keep a
    /// snapshot path + agent ID; if the registry entry was removed or the
    /// snapshotted path is gone, fall back to a live environment / registry
    /// socket so connections keep working.
    func resolveSocketPath(for agentInfo: ExternalAgentKeyInfo) -> String {
        if let path = socketPath(forAgentID: agentInfo.agentID), Self.socketAppearsPresent(path) {
            return path
        }
        if Self.socketAppearsPresent(agentInfo.socketPath) {
            return agentInfo.socketPath
        }
        if let envPath = Self.currentEnvironmentSocketPath(), Self.socketAppearsPresent(envPath) {
            Self.logger.info("Healing stale agent socket \(agentInfo.socketPath, privacy: .public) → env \(envPath, privacy: .public)")
            return envPath
        }
        for agent in agents {
            let path = liveSocketPath(for: agent)
            if Self.socketAppearsPresent(path) {
                Self.logger.info("Healing stale agent socket \(agentInfo.socketPath, privacy: .public) → registry \(path, privacy: .public)")
                return path
            }
        }
        return agentInfo.socketPath
    }

    /// For `$SSH_AUTH_SOCK` entries, prefer the live environment value when the
    /// stored launchd path has disappeared.
    private func liveSocketPath(for agent: ExternalSSHAgent) -> String {
        guard agent.source == .environment else { return agent.socketPath }
        if Self.socketAppearsPresent(agent.socketPath) {
            return agent.socketPath
        }
        if let envPath = Self.currentEnvironmentSocketPath(), Self.socketAppearsPresent(envPath) {
            if envPath != agent.socketPath {
                updateSocketPath(id: agent.id, to: envPath)
            }
            return envPath
        }
        return agent.socketPath
    }

    private nonisolated static func currentEnvironmentSocketPath() -> String? {
        let env = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        guard let env, !env.isEmpty else { return nil }
        return env
    }

    private nonisolated static func socketAppearsPresent(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(agents) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Reachability

    func refreshReachability() async {
        // Heal stale launchd `$SSH_AUTH_SOCK` paths before probing.
        for agent in agents where agent.source == .environment {
            _ = liveSocketPath(for: agent)
        }
        let targets = agents.map { ($0.id, liveSocketPath(for: $0)) }
        var results: [UUID: Bool] = [:]
        for (id, path) in targets {
            results[id] = await Task.detached(priority: .userInitiated) {
                ExternalSSHAgentClient.probe(socketPath: path)
            }.value
        }
        reachability = results
    }

    // MARK: - Discovery

    /// Candidate agents found on this Mac, excluding ones already registered.
    /// Candidates are NOT auto-added; the UI offers them.
    func discoverCandidates() async -> [(agent: ExternalSSHAgent, reachable: Bool)] {
        let registeredPaths = Set(agents.map { standardize($0.socketPath) })
        let ownAgentPath = LocalSSHAgentManager.shared.socketPath.map { standardize($0) }

        let candidates = await Task.detached(priority: .userInitiated) {
            Self.scanCandidates()
        }.value

        var seen = Set<String>()
        var results: [(ExternalSSHAgent, Bool)] = []
        for candidate in candidates {
            let path = standardize(candidate.socketPath)
            guard !path.isEmpty,
                  !registeredPaths.contains(path),
                  path != ownAgentPath,
                  seen.insert(path).inserted else { continue }
            let reachable = await Task.detached(priority: .userInitiated) {
                ExternalSSHAgentClient.probe(socketPath: path)
            }.value
            results.append((candidate, reachable))
        }
        return results
    }

    /// Blocking filesystem/config scan; run off-main.
    private nonisolated static func scanCandidates() -> [ExternalSSHAgent] {
        var candidates: [ExternalSSHAgent] = []

        if FileManager.default.fileExists(atPath: onePasswordSocketPath) {
            candidates.append(ExternalSSHAgent(
                name: "1Password",
                socketPath: onePasswordSocketPath,
                source: .onePassword
            ))
        }

        candidates.append(contentsOf: sshConfigCandidates())

        if let envSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           !envSock.isEmpty {
            candidates.append(ExternalSSHAgent(
                name: "SSH_AUTH_SOCK",
                socketPath: envSock,
                source: .environment
            ))
        }

        return candidates
    }

    private nonisolated static func sshConfigCandidates() -> [ExternalSSHAgent] {
        let home = NSHomeDirectory()
        let sshDirectory = URL(fileURLWithPath: home).appendingPathComponent(".ssh")
        let configURL = sshDirectory.appendingPathComponent("config")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let result = try? OpenSSHConfigParser.parse(fileURL: configURL, sshDirectory: sshDirectory) else {
            return []
        }

        var candidates: [ExternalSSHAgent] = []
        for entry in result.entries {
            guard let raw = entry.identityAgent,
                  let path = resolveIdentityAgentValue(raw, home: home) else { continue }
            let host = entry.aliases.first ?? "?"
            candidates.append(ExternalSSHAgent(
                name: entry.isWildcard && entry.aliases == ["*"]
                    ? String(localized: "ssh config", comment: "Agent discovered from a Host * block")
                    : String(localized: "ssh config (\(host))", comment: "Agent discovered from a ssh config Host block"),
                socketPath: path,
                source: .sshConfig
            ))
        }
        return candidates
    }

    /// Resolve an `IdentityAgent` value to a socket path. Handles `none`
    /// (returns nil), the `SSH_AUTH_SOCK` literal and `$VAR`/`${VAR}` forms
    /// (environment lookup), and `~` expansion.
    nonisolated static func resolveIdentityAgentValue(_ raw: String, home: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.caseInsensitiveCompare("none") == .orderedSame { return nil }

        if value == "SSH_AUTH_SOCK" || value == "$SSH_AUTH_SOCK" || value == "${SSH_AUTH_SOCK}" {
            let env = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            return (env?.isEmpty == false) ? env : nil
        }
        if value.hasPrefix("$") {
            var name = String(value.dropFirst())
            if name.hasPrefix("{"), name.hasSuffix("}") {
                name = String(name.dropFirst().dropLast())
            }
            let env = ProcessInfo.processInfo.environment[name]
            return (env?.isEmpty == false) ? env : nil
        }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + value.dropFirst(1) }
        return value
    }

    private nonisolated func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

#endif
