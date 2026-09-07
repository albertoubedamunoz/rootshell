//
//  ExternalSSHAgentRegistry.swift
//  rootshell (Catalyst, Standalone)
//
//  Persisted list of external OpenSSH agents the user has configured, plus
//  discovery of candidates: the 1Password agent's well-known socket,
//  IdentityAgent directives in ~/.ssh/config, and $SSH_AUTH_SOCK. Nothing
//  secret is stored — an agent entry is just a display name and socket path.
//  Entries backed by an environment variable resolve it at use time because
//  launchd rotates $SSH_AUTH_SOCK on every login.
//

#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation

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
    /// Variable whose live value is the socket. Only set when the value is
    /// launchd's rotating listener; any other path is stored literally so a
    /// stable agent is never retargeted. `socketPath` is then a fallback.
    var environmentVariable: String?

    init(
        id: UUID = UUID(),
        name: String,
        socketPath: String,
        source: Source,
        environmentVariable: String? = nil,
        addedDate: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.socketPath = socketPath
        self.source = source
        self.environmentVariable = environmentVariable
        self.addedDate = addedDate
    }
}

@MainActor
@Observable
final class ExternalSSHAgentRegistry {
    static let shared = ExternalSSHAgentRegistry()

    private static let defaultsKey = "externalSSHAgents"
    /// How long a verified socket is trusted without re-probing.
    private static let positiveResolutionTTL: TimeInterval = 30
    /// How long a "nobody serves this key" sweep result is trusted.
    private static let negativeResolutionTTL: TimeInterval = 60

    nonisolated static let onePasswordSocketPath =
        NSHomeDirectory() + "/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    private(set) var agents: [ExternalSSHAgent] = []
    /// Transient probe results, refreshed on demand. Missing key = not probed yet.
    private(set) var reachability: [UUID: Bool] = [:]

    /// Outcome of `verifyAgent` for one key. `socketPath == nil` records a
    /// sweep that found no agent serving the key.
    private struct KeyResolution {
        let agentID: UUID?
        let socketPath: String?
        let at: Date
    }
    /// Public key blob → verified resolution. Cleared on every registry change.
    private var keyResolutions: [Data: KeyResolution] = [:]
    /// Bumped on every registry change so a sweep suspended across the
    /// change does not write a stale result.
    private var generation = 0
    /// Sweeps in progress, so concurrent callers share one probe per key.
    private var inFlightVerifications: [Data: (id: UUID, task: Task<ExternalSSHAgent?, Never>)] = [:]

    // The inherited environment is stable for this process. Avoid copying
    // it, or locating the app container, for each SwiftUI row lookup.
    private static let environment = ProcessInfo.processInfo.environment
    private static let ownAgentPath = LocalSSHAgentManager.socketPath().map(standardize)

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([ExternalSSHAgent].self, from: data) {
            // Rows pointing at the app's own agent predate the add guard;
            // keeping them would let signing recurse through ourselves.
            agents = stored.map(Self.migrated).filter { !isOwnAgentSocket($0.socketPath) }
        }
    }

    /// Normalizes a row from any source: a launchd listener path is
    /// `$SSH_AUTH_SOCK`-backed whether it arrived from discovery, a manual
    /// add, or persistence that predates `environmentVariable`.
    private nonisolated static func migrated(_ agent: ExternalSSHAgent) -> ExternalSSHAgent {
        var agent = agent
        if agent.environmentVariable == nil, ExternalSSHAgentClient.isLaunchdListenerPath(agent.socketPath) {
            agent.environmentVariable = "SSH_AUTH_SOCK"
        }
        return agent
    }

    // MARK: - CRUD

    /// False when the agent is already registered or is the app's own socket.
    @discardableResult
    func add(_ agent: ExternalSSHAgent) -> Bool {
        let agent = Self.migrated(agent)
        guard !isRegistered(agent), !isOwnAgentSocket(agent.socketPath) else { return false }
        agents.append(agent)
        registryChanged()
        return true
    }

    func remove(id: UUID) {
        agents.removeAll { $0.id == id }
        reachability[id] = nil
        registryChanged()
    }

    func rename(id: UUID, to name: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].name = name
        persist()
    }

    func updateSocketPath(id: UUID, to path: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index] = Self.migrated(ExternalSSHAgent(
            id: agents[index].id,
            name: agents[index].name,
            socketPath: path,
            source: agents[index].source,
            addedDate: agents[index].addedDate
        ))
        reachability[id] = nil
        registryChanged()
    }

    func agent(id: UUID) -> ExternalSSHAgent? {
        agents.first { $0.id == id }
    }

    private func registryChanged() {
        keyResolutions.removeAll()
        generation += 1
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(agents) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Identity

    /// The one predicate for "these rows describe the same agent", shared by
    /// discovery, `add`, and key lookup: same environment variable, or any
    /// socket one row may be reached at is one the other may be reached at.
    private func describesSameAgent(_ a: ExternalSSHAgent, _ b: ExternalSSHAgent) -> Bool {
        if let variable = a.environmentVariable, variable == b.environmentVariable { return true }
        let aPaths = Set(candidatePaths(for: a).map(Self.standardize))
        let bPaths = Set(candidatePaths(for: b).map(Self.standardize))
        return !aPaths.isDisjoint(with: bPaths)
    }

    private func isRegistered(_ candidate: ExternalSSHAgent) -> Bool {
        agents.contains { describesSameAgent($0, candidate) }
    }

    /// The row that is the same agent the key was imported from, when the
    /// key's own row (by ID) is gone: e.g. removed and re-added.
    private func recreatedAgent(matching agentInfo: ExternalAgentKeyInfo) -> ExternalSSHAgent? {
        let snapshot = Self.migrated(ExternalSSHAgent(name: "", socketPath: agentInfo.socketPath, source: .manual))
        return agents.first { describesSameAgent($0, snapshot) }
    }

    /// Use the same rotation policy as the signing client, with this row's
    /// variable. Retain the stored path as a fallback if the current listener
    /// does not serve the key.
    private func candidatePaths(for agent: ExternalSSHAgent) -> [String] {
        let healed = ExternalSSHAgentClient.healedLaunchdListenerPath(
            agent.socketPath,
            environmentVariable: agent.environmentVariable ?? "SSH_AUTH_SOCK",
            environment: Self.environment
        )
        if healed != agent.socketPath, !isOwnAgentSocket(healed) {
            return [healed, agent.socketPath]
        }
        return [agent.socketPath]
    }

    /// rootshell's own local agent; registering it would sign recursively.
    func isOwnAgentSocket(_ path: String) -> Bool {
        Self.standardize(path) == Self.ownAgentPath
    }

    /// Cheap pre-filter only: a present file may still be a dead socket,
    /// so `verifyAgent` always connects before trusting a path.
    private nonisolated static func socketExists(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    /// Canonical form for comparing socket paths. Resolves symlinks so an
    /// alias of the app's own agent socket cannot slip past the exclusions.
    private nonisolated static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Resolution

    /// Row-level socket with no key in hand. Keys go through
    /// `resolveSocketPath`, which prefers a result verified against the key.
    func effectiveSocketPath(for agent: ExternalSSHAgent) -> String {
        candidatePaths(for: agent)[0]
    }

    /// Current socket path for an agent-backed key. Prefers the live registry
    /// entry (the user may have re-pointed the agent) over the path snapshot
    /// stored on the key.
    func socketPath(forAgentID id: UUID) -> String? {
        agent(id: id).map { effectiveSocketPath(for: $0) }
    }

    /// Registry row for an imported key: a positive resolution is authoritative,
    /// including a rowless hit. Before verification or after a miss, use its own
    /// entry or the same agent re-added under a new ID. A failed probe does not
    /// mean the configured row was removed. Pure lookup, safe in view bodies.
    func agent(for agentInfo: ExternalAgentKeyInfo, publicKeyBlob: Data?) -> ExternalSSHAgent? {
        if let publicKeyBlob, let resolution = keyResolutions[publicKeyBlob],
           resolution.socketPath != nil {
            return resolution.agentID.flatMap { agent(id: $0) }
        }
        return agent(id: agentInfo.agentID) ?? recreatedAgent(matching: agentInfo)
    }

    /// Socket for an imported external-agent key: the verified result when
    /// `verifyAgent` has run for this key, else the best unverified guess
    /// (own row, identity-matched row, import-time snapshot). Pure lookup;
    /// never the app's own socket.
    func resolveSocketPath(for agentInfo: ExternalAgentKeyInfo, publicKeyBlob: Data?) -> String {
        if let publicKeyBlob, let path = keyResolutions[publicKeyBlob]?.socketPath {
            if !isOwnAgentSocket(path) { return path }
        }
        if let agent = agent(id: agentInfo.agentID) ?? recreatedAgent(matching: agentInfo) {
            let path = effectiveSocketPath(for: agent)
            if !isOwnAgentSocket(path) { return path }
        }
        return isOwnAgentSocket(agentInfo.socketPath) ? "" : agentInfo.socketPath
    }

    /// Find and cache the socket that actually serves this key. Tiers, each
    /// tried only when earlier tiers do not advertise the key, so a key
    /// stays with its agent while that agent serves it:
    ///   1. the key's own or recreated row (healed listener, then stored path)
    ///   2. the import-time snapshot
    ///   3. other rows, the identity-matched one first
    /// A socket counts only if it answers a list request and advertises the
    /// key. The app's own agent re-advertises these keys and is never used.
    /// Only an explicit (`force`) check contacts unrelated registered agents.
    /// It also bypasses cached results and any earlier in-flight check.
    @discardableResult
    func verifyAgent(for agentInfo: ExternalAgentKeyInfo, publicKeyBlob: Data, force: Bool = false) async -> ExternalSSHAgent? {
        if !force, let running = inFlightVerifications[publicKeyBlob] {
            return await running.task.value
        }
        let requestID = UUID()
        let task = Task { await sweep(for: agentInfo, publicKeyBlob: publicKeyBlob, force: force, requestID: requestID) }
        inFlightVerifications[publicKeyBlob] = (requestID, task)
        defer {
            if inFlightVerifications[publicKeyBlob]?.id == requestID {
                inFlightVerifications[publicKeyBlob] = nil
            }
        }
        return await task.value
    }

    /// `verifyAgent` for a saved key ID; no-op for non-agent keys.
    func verifyAgent(forKeyID keyID: UUID) async {
        guard let key = SSHKeyManager.shared.findKey(id: keyID),
              let agentInfo = key.externalAgentInfo,
              let publicKeyBlob = key.publicKeyBlob else { return }
        await verifyAgent(for: agentInfo, publicKeyBlob: publicKeyBlob)
    }

    private func sweep(for agentInfo: ExternalAgentKeyInfo, publicKeyBlob: Data, force: Bool, requestID: UUID) async -> ExternalSSHAgent? {
        let startGeneration = generation

        typealias Candidate = (agentID: UUID?, path: String)
        var tier1: [Candidate] = []
        if let own = agent(id: agentInfo.agentID) ?? recreatedAgent(matching: agentInfo) {
            tier1 += candidatePaths(for: own).map { Candidate(agentID: own.id, path: $0) }
        }
        // The snapshot is attributed to the row that is the same agent so the
        // row and socket lookups agree; skipped if tier 1 already covers it.
        let snapshot = Self.standardize(agentInfo.socketPath)
        if !tier1.contains(where: { Self.standardize($0.path) == snapshot }) {
            tier1.append(Candidate(agentID: recreatedAgent(matching: agentInfo)?.id, path: agentInfo.socketPath))
        }

        var hit: Candidate?
        var checkedTier1 = false
        var seenPaths: Set<String> = []
        if !force, let cached = keyResolutions[publicKeyBlob] {
            let age = Date().timeIntervalSince(cached.at)
            if let path = cached.socketPath, !isOwnAgentSocket(path) {
                if age < Self.positiveResolutionTTL {
                    return cached.agentID.flatMap { agent(id: $0) }
                }
                // A fallback must yield to the original agent when it recovers.
                if cached.agentID != agentInfo.agentID {
                    hit = await firstServing(tier1, publicKeyBlob, seenPaths: &seenPaths)
                    checkedTier1 = true
                }
                if hit == nil {
                    hit = await firstServing([(cached.agentID, path)], publicKeyBlob, seenPaths: &seenPaths)
                }
            } else if cached.socketPath == nil, age < Self.negativeResolutionTTL {
                return nil
            }
        }
        if hit == nil, !checkedTier1 {
            hit = await firstServing(tier1, publicKeyBlob, seenPaths: &seenPaths)
        }
        if hit == nil, force {
            let others = agents.filter { $0.id != agentInfo.agentID }
            let recreated = recreatedAgent(matching: agentInfo)
            let tier2: [Candidate] = (others.filter { $0.id == recreated?.id } + others.filter { $0.id != recreated?.id })
                .flatMap { agent in candidatePaths(for: agent).map { Candidate(agentID: agent.id, path: $0) } }
            hit = await firstServing(tier2, publicKeyBlob, seenPaths: &seenPaths)
        }
        // A newer forced check or registry edit supersedes this result.
        let hitRow = hit?.agentID.flatMap { agent(id: $0) }
        if generation == startGeneration, inFlightVerifications[publicKeyBlob]?.id == requestID {
            keyResolutions[publicKeyBlob] = KeyResolution(agentID: hit?.agentID, socketPath: hit?.path, at: Date())
        }
        return hitRow
    }

    private nonisolated static func serves(_ publicKeyBlob: Data, at path: String) async -> Bool {
        guard socketExists(path) else { return false }
        return await Task.detached(priority: .userInitiated) {
            ExternalSSHAgentClient.serves(publicKeyBlob: publicKeyBlob, socketPath: path)
        }.value
    }

    /// Probe in order, stopping at the first hit so later agents receive no
    /// requests (listing can display an unlock prompt). Share canonical paths
    /// across the sweep's tiers and cache re-check to probe each socket once.
    private func firstServing(
        _ candidates: [(agentID: UUID?, path: String)],
        _ publicKeyBlob: Data,
        seenPaths: inout Set<String>
    ) async -> (agentID: UUID?, path: String)? {
        for candidate in candidates {
            guard seenPaths.insert(Self.standardize(candidate.path)).inserted,
                  !isOwnAgentSocket(candidate.path) else { continue }
            if await Self.serves(publicKeyBlob, at: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Reachability

    func refreshReachability() async {
        let targets = agents.map { ($0.id, effectiveSocketPath(for: $0)) }
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
        // Normalized here so exclusion sees the exact row `add` would store.
        let candidates = await Task.detached(priority: .userInitiated) {
            Self.scanCandidates().map(Self.migrated)
        }.value

        var results: [(ExternalSSHAgent, Bool)] = []
        for candidate in candidates {
            let path = effectiveSocketPath(for: candidate)
            guard !path.isEmpty,
                  !isOwnAgentSocket(path),
                  !isRegistered(candidate),
                  !results.contains(where: { describesSameAgent($0.0, candidate) }) else { continue }
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
                  let target = resolveIdentityAgentValue(raw, home: home) else { continue }
            let host = entry.aliases.first ?? "?"
            // A variable is kept only when its value rotates (launchd); a
            // literal value in a variable is still a literal agent.
            let rotates = ExternalSSHAgentClient.isLaunchdListenerPath(target.socketPath)
            candidates.append(ExternalSSHAgent(
                name: entry.isWildcard && entry.aliases == ["*"]
                    ? String(localized: "ssh config", comment: "Agent discovered from a Host * block")
                    : String(localized: "ssh config (\(host))", comment: "Agent discovered from a ssh config Host block"),
                socketPath: target.socketPath,
                source: .sshConfig,
                environmentVariable: rotates ? target.environmentVariable : nil
            ))
        }
        return candidates
    }

    /// Resolve an `IdentityAgent` value to a socket path. Handles `none`
    /// (returns nil), the `SSH_AUTH_SOCK` literal and `$VAR`/`${VAR}` forms
    /// (environment lookup, variable name reported), and `~` expansion.
    nonisolated static func resolveIdentityAgentValue(
        _ raw: String,
        home: String
    ) -> (socketPath: String, environmentVariable: String?)? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.caseInsensitiveCompare("none") == .orderedSame { return nil }

        var variable: String?
        if value == "SSH_AUTH_SOCK" {
            variable = "SSH_AUTH_SOCK"
        } else if value.hasPrefix("$") {
            var name = String(value.dropFirst())
            if name.hasPrefix("{"), name.hasSuffix("}") {
                name = String(name.dropFirst().dropLast())
            }
            variable = name
        }
        if let variable {
            let env = ProcessInfo.processInfo.environment[variable]
            guard let env, !env.isEmpty else { return nil }
            return (env, variable)
        }
        if value == "~" { return (home, nil) }
        if value.hasPrefix("~/") { return (home + value.dropFirst(1), nil) }
        return (value, nil)
    }
}

#endif
