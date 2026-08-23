#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation
import Observation

nonisolated enum LocalAgentClientKey: Codable, Hashable, Sendable, CustomStringConvertible {
    case platform(signingID: String)
    case team(teamID: String, signingID: String)
    case cdhash(Data)

    var description: String {
        switch self {
        case .platform(let signingID):
            return "platform:\(signingID)"
        case .team(let teamID, let signingID):
            return "team:\(teamID):\(signingID)"
        case .cdhash(let data):
            return "cdhash:\(data.map { String(format: "%02x", $0) }.joined())"
        }
    }
}

nonisolated struct LocalAgentClientRule: Codable, Identifiable, Hashable, Sendable {
    enum Policy: String, Codable, CaseIterable, Sendable {
        case allow
        case askSession
        case askAlways
        case deny

        var displayName: String {
            switch self {
            case .allow:
                return String(localized: "Always Allow", comment: "Local SSH agent client rule policy")
            case .askSession:
                return String(localized: "Ask Once per Session", comment: "Local SSH agent client rule policy")
            case .askAlways:
                return String(localized: "Ask Every Time", comment: "Local SSH agent client rule policy")
            case .deny:
                return String(localized: "Deny", comment: "Local SSH agent client rule policy")
            }
        }
    }

    let id: UUID
    let key: LocalAgentClientKey
    var displayName: String
    var lastPath: String
    var policy: Policy
    var allowedKeyIDs: Set<UUID>?
    var requireSessionBind: Bool
    var pinnedHostKeyFingerprints: Set<String>
    let createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        key: LocalAgentClientKey,
        displayName: String,
        lastPath: String,
        policy: Policy,
        allowedKeyIDs: Set<UUID>? = nil,
        requireSessionBind: Bool = false,
        pinnedHostKeyFingerprints: Set<String> = [],
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.displayName = displayName
        self.lastPath = lastPath
        self.policy = policy
        self.allowedKeyIDs = allowedKeyIDs
        self.requireSessionBind = requireSessionBind
        self.pinnedHostKeyFingerprints = pinnedHostKeyFingerprints
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

nonisolated struct LocalAgentConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var exposedKeyIDs: Set<UUID> = []
    var signatureApprovalMode: SSHAgentConfig.ApprovalMode = .sessionApprove
}

@MainActor
@Observable
final class LocalAgentPolicyStore {
    static let shared = LocalAgentPolicyStore()

    private enum Keys {
        static let rules = "localAgent.clientRules"
        static let config = "localAgent.config"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var rules: [LocalAgentClientRule] = []
    var config: LocalAgentConfig {
        didSet {
            saveConfig()
            LocalSSHAgentManager.shared.configDidChange()
        }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.rules),
           let decoded = try? decoder.decode([LocalAgentClientRule].self, from: data) {
            self.rules = decoded
        }
        if let data = defaults.data(forKey: Keys.config),
           let decoded = try? decoder.decode(LocalAgentConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = LocalAgentConfig()
        }
    }

    nonisolated static func activeSocketPathFromDefaults() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "localAgent.config"),
              let config = try? JSONDecoder().decode(LocalAgentConfig.self, from: data),
              config.enabled,
              let container = AppGroupHelper.containerURL else {
            return nil
        }
        return container.appendingPathComponent("agent.sock").path
    }

    func rule(for key: LocalAgentClientKey) -> LocalAgentClientRule? {
        rules.first { $0.key == key }
    }

    func upsertRule(_ rule: LocalAgentClientRule) {
        if let index = rules.firstIndex(where: { $0.key == rule.key }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        saveRules()
        LocalSSHAgentManager.shared.invalidateClientGateCache()
    }

    func updateRule(_ rule: LocalAgentClientRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        saveRules()
        LocalSSHAgentManager.shared.invalidateClientGateCache()
    }

    func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
        LocalSSHAgentManager.shared.invalidateClientGateCache()
    }

    func noteUsed(key: LocalAgentClientKey, path: String?) {
        guard let index = rules.firstIndex(where: { $0.key == key }) else { return }
        rules[index].lastUsedAt = Date()
        if let path { rules[index].lastPath = path }
        saveRules()
    }

    private func saveRules() {
        if let data = try? encoder.encode(rules) {
            defaults.set(data, forKey: Keys.rules)
        }
    }

    private func saveConfig() {
        if let data = try? encoder.encode(config) {
            defaults.set(data, forKey: Keys.config)
        }
    }
}

#endif
