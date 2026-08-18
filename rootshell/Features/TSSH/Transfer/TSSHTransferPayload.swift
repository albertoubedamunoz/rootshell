//
//  TSSHTransferPayload.swift
//  rootshell
//
//  Bootstrap payload sent over the Handoff continuation stream from the
//  originating device to the receiving device. Contains everything needed
//  to call TrzszGoTransport.attachToSession(...) on the new device, plus
//  the recent terminal scrollback so the user sees a seamless transition.
//

import Foundation

nonisolated struct TrzszTransferPayload: Codable, Sendable {
    /// Schema version. Bumped when fields are added/changed in incompatible
    /// ways. Receiver compares against `TrzszTransferActivity.payloadVersion`.
    let version: Int

    /// Server-side reattach material (sessionID, certs/keys, ports).
    let credentials: TrzszSessionCredentials

    /// Original SSH connection config. Used by the receiver to populate
    /// connection-info, history, and tab title — not needed for attach,
    /// since attach uses the server-issued sessionID directly.
    let sshConfig: SSHConfig

    /// Transport mode preference at time of transfer.
    let transportMode: TrzszConfig.TransportMode

    /// Display name (e.g. "user@host") for the receiving tab's title.
    let displayName: String

    /// Live terminal dimensions at offer time. Receiver passes these to
    /// `attachToSession` so tsshd resizes immediately to match the new
    /// device's geometry.
    let cols: UInt16
    let rows: UInt16

    /// ANSI-styled byte dump of the primary screen (scrollback + viewport),
    /// truncated to the last `maxScrollbackBytes`. Receiver writes this
    /// into its surface BEFORE attach output starts so the user sees recent
    /// history.
    let primaryScrollback: Data

    /// Optional dump of the alternate screen if a TUI is active at transfer
    /// time. Receiver enters alt-screen mode and writes this before attach
    /// resumes so vim/htop/etc. don't flicker through the primary screen.
    let alternateScreen: Data?

    /// Wall-clock time when the session originally started (used to keep
    /// the connection-info "connected at" stable across the transfer).
    let sessionStartedAt: Date

    /// Human-readable name of the device offering the transfer (shown in
    /// the receiver's accept sheet).
    let originDeviceName: String

    /// Cap on scrollback bytes carried in the payload. Tail is preserved,
    /// head is dropped — most recent activity is what the user wants.
    static let maxScrollbackBytes: Int = 256 * 1024
}

nonisolated extension TrzszTransferPayload {
    /// Truncates an ANSI dump to the last `maxScrollbackBytes` bytes. The
    /// raw byte cut may land in the middle of an ANSI escape sequence; that
    /// would only affect color/style of the very first row on the receiver
    /// (until tsshd's first output rewrites the cursor), so we accept it
    /// rather than parsing the stream.
    static func truncatedScrollback(_ data: Data, max: Int = maxScrollbackBytes) -> Data {
        guard data.count > max else { return data }
        return data.suffix(max)
    }
}
