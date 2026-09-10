import Foundation

/// Optional: absence preserves the historical SSH-bootstrap-only jump route.
/// CloudKit stores this separately from the legacy SSH config (old writers
/// reconstruct that config and would erase fields they do not understand).
nonisolated struct TSSHRelaySettings: Codable, Hashable, Sendable {
    var serverPath: String?
    var udpPortMin: Int?
    var udpPortMax: Int?
    var boundJump: TSSHRelayIdentity?

    init(serverPath: String? = nil, udpPortMin: Int? = nil, udpPortMax: Int? = nil,
         boundJump: TSSHRelayIdentity? = nil) {
        self.serverPath = serverPath
        self.udpPortMin = udpPortMin
        self.udpPortMax = udpPortMax
        self.boundJump = boundJump
    }

    func validate(host: String, port: Int, username: String,
                  defaultPortMin: Int, defaultPortMax: Int) throws {
        if let boundJump, boundJump != TSSHRelayIdentity(host: host, port: port, username: username) {
            throw TSSHRelayConfigurationError("The jump host changed on another device. Review and save its tssh relay settings before connecting.")
        }
        let low = udpPortMin ?? defaultPortMin
        let high = udpPortMax ?? defaultPortMax
        guard (1...65535).contains(low), (1...65535).contains(high), low <= high else {
            throw TSSHRelayConfigurationError("The jump host UDP range must be within 1–65535, with minimum no greater than maximum.")
        }
    }
}

nonisolated struct TSSHRelayIdentity: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var username: String

    init(host: String, port: Int, username: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
        self.username = username
    }
}

nonisolated struct TSSHRelayConfigurationError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
