//
//  CitadelStreamLocalPipe.swift
//  rootshell
//
//  GPG-facing facade over ``NIOChannelBytePipe`` for channels delivered
//  by Citadel's `forwardRemoteUnixSocket` callback. Adds Citadel's
//  StreamLocalChannelHandler ahead of the pipe so the raw streamlocal
//  channel data is unwrapped into plain ByteBuffers.
//
//  Mirrors the TSSHD-side ``TrzszStreamLocalPipe`` in role and
//  contract so the Assuan server doesn't care which SSH transport
//  delivered the connection.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import Citadel

nonisolated enum CitadelStreamLocalPipe {

    /// Install a byte pipe + the Citadel streamlocal unwrapping handler
    /// on the given channel. Must be called on the channel's event loop
    /// (Citadel hands the channel over on its event loop in the
    /// `handleChannel` callback).
    static func install(on channel: Channel) throws -> NIOChannelBytePipe {
        try NIOChannelBytePipe.install(
            on: channel,
            extraHandlers: [StreamLocalChannelHandler()]
        )
    }
}
