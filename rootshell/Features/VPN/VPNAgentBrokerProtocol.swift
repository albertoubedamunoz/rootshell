//
//  VPNAgentBrokerProtocol.swift
//  rootshell
//
//  Wire types for the VPN agent signing broker (macOS). The packet tunnel
//  runs as a root system extension that can neither reach a user-session
//  ssh-agent socket nor initiate IPC to the host, so signing is inverted
//  into a long-poll: the host keeps an `agent.poll` sendProviderMessage
//  outstanding; when the sysext's SSH auth needs a signature it answers the
//  poll with a challenge, the host signs it against the agent socket in user
//  context, and submits the result via `agent.submit`.
//
//  Provider messages (UTF-8 strings over sendProviderMessage):
//    "agent.poll"              -> reply: empty Data (no work) or JSON VPNAgentSignChallenge
//    "agent.submit <JSON>"     -> JSON VPNAgentSignSubmission; reply: "ok"
//

import Foundation

nonisolated enum VPNAgentBrokerMessage {
    static let poll = "agent.poll"
    static let submitPrefix = "agent.submit "

    /// Sysext parks a poll for at most this long before replying empty; the
    /// host's watchdog must exceed it.
    static let pollParkSeconds: TimeInterval = 25
    /// Host-side watchdog for one poll round trip.
    static let pollWatchdogSeconds: TimeInterval = 35
    /// How long a sysext sign request waits for the host to deliver a
    /// signature (the agent may show an interactive approval dialog).
    static let signTimeoutSeconds: TimeInterval = 120
    /// If no poll has been seen recently, sign requests fail after this
    /// grace instead of waiting out the full sign timeout — the host is
    /// gone and reconnect backoff should take over.
    static let brokerAbsentGraceSeconds: TimeInterval = 10
}

/// A userauth signature the sysext needs from the host.
nonisolated struct VPNAgentSignChallenge: Codable, Sendable {
    let requestID: UUID
    /// Agent socket to sign against (from the resolved credential).
    let socketPath: String
    /// SSH public key blob identifying the key inside the agent.
    let keyBlob: Data
    /// Exact bytes to sign (the SSH userauth signable payload).
    let data: Data
    /// ssh-agent sign flags (2 = rsa-sha2-256, 4 = rsa-sha2-512).
    let flags: UInt32
}

/// Host's answer to a challenge.
nonisolated struct VPNAgentSignSubmission: Codable, Sendable {
    let requestID: UUID
    /// Raw SSH signature blob (string algorithm + string signature), or nil
    /// on failure.
    let signature: Data?
    /// Human-readable failure reason when `signature` is nil.
    let error: String?
}
