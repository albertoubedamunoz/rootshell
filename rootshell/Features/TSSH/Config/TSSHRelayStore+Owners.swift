import Foundation

extension TSSHRelayStore {
    func applying(to profile: ConnectionProfile) -> ConnectionProfile {
        guard let record = record(owner: .profile, key: profile.id.uuidString) else { return profile }
        var result = profile
        result.sshConfig.jumpHost?.tsshRelay = record.isDeleted ? nil : record.settings
        return result
    }

    func applying(to entry: SSHConnectionHistoryEntry) -> SSHConnectionHistoryEntry {
        guard let record = record(owner: .history, key: entry.connectionIdentity) else { return entry }
        var result = entry
        result.tsshRelay = record.isDeleted ? nil : record.settings
        return result
    }
}
