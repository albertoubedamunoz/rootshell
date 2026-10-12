import Foundation

extension TSSHRelayStore {
    func applying(to profile: ConnectionProfile) -> ConnectionProfile {
        guard let record = record(owner: .profile, key: profile.id.uuidString) else { return profile }
        var result = profile
        let relays = record.isDeleted ? [] : record.relays
        result.sshConfig.jumpChain = result.sshConfig.jumpChain.enumerated().map { index, hop in
            var hop = hop
            hop.tsshRelay = index < relays.count ? relays[index] : nil
            return hop
        }
        return result
    }

    func applying(to entry: SSHConnectionHistoryEntry) -> SSHConnectionHistoryEntry {
        guard let record = record(owner: .history, key: entry.connectionIdentity) else { return entry }
        var result = entry
        let relays = record.isDeleted ? [] : record.relays
        result.tsshRelay = relays.first
        result.extraJumpHops = result.extraJumpHops?.enumerated().map { index, hop in
            var hop = hop
            hop.tsshRelay = index + 1 < relays.count ? relays[index + 1] : nil
            return hop
        }
        return result
    }
}

extension SSHConfig {
    /// Relay settings of the leading relay hops, hop 1 first.
    var relayChain: [TSSHRelaySettings] {
        relayHops.compactMap(\.tsshRelay)
    }
}
