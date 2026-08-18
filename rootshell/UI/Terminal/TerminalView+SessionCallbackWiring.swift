//
//  TerminalView+SessionCallbackWiring.swift
//  rootshell
//
//  Small reusable helpers for the per-session-type callback wiring in
//  setupPTYAndShell. These deduplicate closures that were byte-identical
//  across several connection paths (agent/GPG-forwarding approvals shared by
//  the SSH and Trzsz paths; the standard error handler shared by the
//  K8s/Console/EC2 and Mosh/Trzsz paths). Pure relocation — no behavior change.
//

import UIKit
import GhosttyKit

extension Ghostty.TerminalView {

    /// Wire this view's agent/GPG-forwarding approval UI onto an SSH-capable
    /// session. Shared by the SSH (Citadel) and Trzsz connection paths, which
    /// used identical closures.
    func wireAgentForwardingApprovals(on session: some SSHAgentForwardingCallbacks) {
        session.onAgentApprovalRequest = { [weak self] request in
            Task { @MainActor in
                self?.onAgentApprovalRequired?(request)
            }
        }
        session.onGPGAgentApprovalRequest = { [weak self] request in
            Task { @MainActor in
                self?.onGPGAgentApprovalRequired?(request)
            }
        }
        session.onGPGAgentApprovalWithdrawn = { [weak self] requestID in
            Task { @MainActor in
                self?.onGPGAgentApprovalWithdrawn?(requestID)
            }
        }
    }

    /// Wire the standard "display the error in the terminal" onError handler.
    /// Shared by the K8s/Console/EC2 paths (`prefix == nil`) and the Mosh/Trzsz
    /// paths (`prefix == "Roam Error"`). The SSH path keeps its own onError
    /// (auth-failure detection / re-auth flow).
    func wireStandardSessionError(on session: some TerminalSession, prefix: String? = nil) {
        session.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleSessionError(error, prefix: prefix)
            }
        }
    }
}
