//
//  VNCConnectionInfo.swift
//  rootshell
//
//  Connection Info payload for VNC screen-sharing panes
//

import Foundation
import rootshellVNC

/// Snapshot of a VNC pane's connection identity plus a handle to the live
/// session for negotiated details and streaming statistics.
struct VNCConnectionInfo: Sendable {
    let host: String
    let port: Int
    let username: String?
    /// App-derived tunnel description ("Direct", "SSH Tunnel via host", …).
    let transportDescription: String
    /// True when an SSH/tssh tunnel wraps the TCP stream, in which case an
    /// unencrypted RFB payload is still protected in transit.
    let isTunneled: Bool
    let connectedAt: Date
    /// Live session for resolution, server name, diagnostics, and statistics.
    let session: VNCSession
}
