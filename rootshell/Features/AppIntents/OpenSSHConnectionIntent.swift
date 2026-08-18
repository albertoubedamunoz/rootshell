//
//  OpenSSHConnectionIntent.swift
//  rootshell
//
//  Shortcuts action that opens an ad-hoc SSH connection to any host.
//

import AppIntents

/// Shortcuts action: connect to an arbitrary SSH host. Connection history
/// fills in authentication for known hosts; unknown hosts get a prefilled
/// connection sheet (same behavior as opening an ssh:// URL).
struct OpenSSHConnectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open SSH Connection"
    static var description: IntentDescription = "Opens an SSH session to any host, using connection history to fill in authentication."
    static var openAppWhenRun = true

    @Parameter(title: "Host")
    var host: String

    @Parameter(title: "Username")
    var username: String?

    @Parameter(title: "Port", default: 22)
    var port: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw IntentError.emptyHost
        }
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = SSHURLComponents(
            host: trimmedHost,
            port: (1...65535).contains(port) ? port : 22,
            username: (trimmedUsername?.isEmpty ?? true) ? nil : trimmedUsername
        )
        AppIntentCoordinator.shared.deposit(.openSSH(components))
        return .result()
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case emptyHost

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .emptyHost:
                return "A host is required."
            }
        }
    }
}
