import Foundation

/// The agent/GPG-forwarding approval callbacks that SSH-capable sessions expose
/// for the view to wire onto its approval UI. `CitadelSSHSession` and
/// `TrzszSession` declare identical members; this protocol lets one helper
/// (`Ghostty.TerminalView.wireAgentForwardingApprovals(on:)`) wire them once
/// instead of duplicating the same three closures in each connection path.
@MainActor
protocol SSHAgentForwardingCallbacks: AnyObject {
    var onAgentApprovalRequest: ((SSHAgentApprovalRequest) -> Void)? { get set }
    var onGPGAgentApprovalRequest: ((GPGAgentApprovalRequest) -> Void)? { get set }
    var onGPGAgentApprovalWithdrawn: ((UUID) -> Void)? { get set }
}

extension CitadelSSHSession: SSHAgentForwardingCallbacks {}
extension TrzszSession: SSHAgentForwardingCallbacks {}
