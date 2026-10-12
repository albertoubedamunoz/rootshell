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

    /// Jump hops in order, never carrying a typed password.
    var jumpHops: [JumpHostDraft] = []

    /// Set by the form being written into: it holds a password, typed or
    /// already in the Keychain, that belongs to the host sitting in its
    /// fields. Rewriting that host would file the secret under a machine it
    /// was never meant for, so carry-over leaves such a form alone.
    var hasHostBoundSecret: Bool = false

    /// Nothing here is worth preserving.
    var isBlank: Bool {
        host.isEmpty && username.isEmpty && jumpHops.isEmpty
    }

    /// Compares only the fields carry-over writes, which is how an untouched
    /// destination is told apart from one the user has since edited.
    func matchesCarriedFields(of other: ConnectionEndpoint) -> Bool {
        host == other.host
            && username == other.username
            && jumpHops.map(\.carriedFields) == other.jumpHops.map(\.carriedFields)
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

        // The jump chain transfers as a whole or not at all: a half-filled
        // tunnel is worse than none, and Screen Sharing holds a single hop.
        let hops = source.jumpHops.map { hop -> JumpHostDraft in
            var carried = hop
            carried.hostname = hop.trimmedHost
            carried.password = ""
            return carried
        }
        let complete = !hops.contains { $0.hostname.isEmpty }
        destination.jumpHops = complete && (side == .sshFamily || hops.count == 1) ? hops : []

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
                jumpHops: jumpSelection == .manual ? [manualJumpDraft] : [],
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

            if let hop = newValue.jumpHops.first {
                jumpSelection = .manual
                jumpHostname = hop.hostname
                jumpPort = hop.port
                jumpUsername = hop.username
                jumpAuthMethod = hop.authMethod
                jumpSelectedKeyID = hop.selectedKeyID
                jumpHasSavedPassword = hop.hasSavedPassword
            } else {
                jumpSelection = .none
                jumpHasSavedPassword = false
            }
        }
    }
}

private extension VNCFormState {
    var manualJumpDraft: JumpHostDraft {
        var draft = JumpHostDraft(hostname: jumpHostname, port: jumpPort, username: jumpUsername,
                                  authMethod: jumpAuthMethod, selectedKeyID: jumpSelectedKeyID)
        draft.hasSavedPassword = jumpHasSavedPassword
        return draft
    }
}
