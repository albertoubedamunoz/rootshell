//
//  ConnectionEndpointCarryOver.swift
//  rootshell
//
//  Carries the endpoint fields across a protocol switch between the SSH
//  family forms and the Screen Sharing form. The two present completely
//  separate field sets, so without this the host the user just typed
//  disappears the moment they flip the picker.
//

import Foundation

/// The connection fields the SSH family and Screen Sharing have in common.
///
/// Ports are deliberately absent: 22 and 5900 mean different things, and an
/// SSH host listening on a custom port says nothing about where its VNC
/// server lives. Passwords are absent too, so a secret typed for one
/// protocol never leaks into the other protocol's Keychain entry.
struct ConnectionEndpoint {
    var host: String = ""
    var username: String = ""

    var usesJumpHost: Bool = false
    var jumpHost: String = ""
    var jumpPort: String = "22"
    var jumpUsername: String = ""
    var jumpAuthMethod: SSHConnectionView.AuthType = .key
    var jumpKeyID: UUID?
    var jumpHasSavedPassword: Bool = false

    /// Set by the form being written into: it holds a password, typed or
    /// already in the Keychain, that belongs to the host sitting in its
    /// fields. Rewriting that host would file the secret under a machine it
    /// was never meant for, so carry-over leaves such a form alone.
    var hasHostBoundSecret: Bool = false

    /// Nothing here is worth preserving.
    var isBlank: Bool {
        host.isEmpty && username.isEmpty && !usesJumpHost
    }

    /// Compares only the fields carry-over writes, which is how an untouched
    /// destination is told apart from one the user has since edited.
    func matchesCarriedFields(of other: ConnectionEndpoint) -> Bool {
        guard host == other.host,
              username == other.username,
              usesJumpHost == other.usesJumpHost else {
            return false
        }
        guard usesJumpHost else { return true }
        return jumpHost == other.jumpHost
            && jumpPort == other.jumpPort
            && jumpUsername == other.jumpUsername
            && jumpAuthMethod == other.jumpAuthMethod
            && jumpKeyID == other.jumpKeyID
    }
}

/// Which form a carry-over is writing into.
enum ConnectionEndpointSide: Hashable {
    case sshFamily
    case screenSharing
}

/// Copies the endpoint from the form the user is leaving into the one they
/// are switching to.
///
/// It writes only into a destination it owns: one that is still blank, or
/// that still holds exactly what an earlier switch put there. Edit any of
/// those fields, or attach a password to them, and the form becomes yours,
/// so nothing is copied into it again. When it does write, it writes the
/// whole set, which keeps a cleared host, username or jump host from
/// lingering on the other side after it is removed from the original.
struct ConnectionEndpointCarryOver {
    private var written: [ConnectionEndpointSide: ConnectionEndpoint] = [:]

    mutating func carry(
        from source: ConnectionEndpoint,
        into destination: inout ConnectionEndpoint,
        side: ConnectionEndpointSide
    ) {
        guard !destination.hasHostBoundSecret else { return }
        guard destination.isBlank
                || written[side].map(destination.matchesCarriedFields) == true else {
            return
        }

        destination.host = source.host.trimmingCharacters(in: .whitespacesAndNewlines)
        destination.username = source.username.trimmingCharacters(in: .whitespacesAndNewlines)

        // The jump host transfers as a whole or not at all: a half-filled
        // tunnel is worse than none.
        let jumpHost = source.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.usesJumpHost, !jumpHost.isEmpty {
            destination.usesJumpHost = true
            destination.jumpHost = jumpHost
            destination.jumpPort = source.jumpPort
            destination.jumpUsername = source.jumpUsername
            destination.jumpAuthMethod = source.jumpAuthMethod
            destination.jumpKeyID = source.jumpKeyID
            destination.jumpHasSavedPassword = source.jumpHasSavedPassword
        } else {
            destination.usesJumpHost = false
            destination.jumpHasSavedPassword = false
        }

        var record = destination
        record.hasHostBoundSecret = false
        written[side] = record
    }
}

// MARK: - Screen Sharing form adapter

extension VNCFormState {
    /// The Screen Sharing fields as the shared endpoint shape. A jump that
    /// points at a saved profile has no SSH-form equivalent, so it reads back
    /// as "no jump" and is left alone on write.
    var endpoint: ConnectionEndpoint {
        get {
            ConnectionEndpoint(
                host: hostname,
                username: username,
                usesJumpHost: jumpSelection == .manual,
                jumpHost: jumpHostname,
                jumpPort: jumpPort,
                jumpUsername: jumpUsername,
                jumpAuthMethod: jumpAuthMethod,
                jumpKeyID: jumpSelectedKeyID,
                jumpHasSavedPassword: jumpHasSavedPassword,
                hasHostBoundSecret: !password.isEmpty
                    || !jumpPassword.isEmpty
                    || jumpHasSavedPassword
            )
        }
        set {
            hostname = newValue.host
            username = newValue.username

            // A jump pointing at a saved profile is the user's own choice.
            guard jumpSelection == .none || jumpSelection == .manual else { return }

            if newValue.usesJumpHost {
                jumpSelection = .manual
                jumpHostname = newValue.jumpHost
                jumpPort = newValue.jumpPort
                jumpUsername = newValue.jumpUsername
                jumpAuthMethod = newValue.jumpAuthMethod
                jumpSelectedKeyID = newValue.jumpKeyID
                jumpHasSavedPassword = newValue.jumpHasSavedPassword
            } else {
                jumpSelection = .none
                jumpHasSavedPassword = false
            }
        }
    }
}
