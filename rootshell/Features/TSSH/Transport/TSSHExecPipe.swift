//
//  TSSHExecPipe.swift
//  rootshell
//
//  AsyncBytePipe over a tsshd auxiliary exec channel. The Go side owns the
//  session; this adapter only moves bytes through the call gate's
//  concurrent worker, so a blocked read never starves other transport calls.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated final class TrzszExecPipe: AsyncBytePipe, @unchecked Sendable {

    private let channelRef: Int64
    private let transportRef: TSSHTransportRef
    /// The server's id for this channel's session, recorded for cleanup.
    let remoteSessionID: UInt64?
    /// Fires on close, so the id stops counting as something to clean up.
    var onRemoteSessionEnded: (@Sendable (UInt64) -> Void)?

    init(channelRef: Int64, transportRef: TSSHTransportRef, remoteSessionID: UInt64? = nil) {
        self.channelRef = channelRef
        self.transportRef = transportRef
        self.remoteSessionID = remoteSessionID
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await TSSHCallGate.shared.execRead(
            on: transportRef,
            channelRef: channelRef,
            maxBytes: maxBytes
        )
    }

    func write(_ data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = try await TSSHCallGate.shared.execWrite(
                on: transportRef,
                channelRef: channelRef,
                data: remaining
            )
            if written <= 0 {
                throw NSError(
                    domain: "TrzszExecPipe",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "exec write made no progress"]
                )
            }
            remaining = remaining.subdata(in: written..<remaining.count)
        }
    }

    /// Exit code once the remote command finished, -1 while it runs.
    func exitCode() async -> Int {
        await TSSHCallGate.shared.execExitCode(on: transportRef, channelRef: channelRef)
    }

    func close() async {
        // Only an exit code proves the remote process is gone. A close that
        // throws, times out, or runs against a dead transport proves nothing,
        // so the id stays recorded for a later sweep.
        let exited = await TSSHCallGate.shared.execExitCode(on: transportRef, channelRef: channelRef) >= 0
        try? await TSSHCallGate.shared.execClose(on: transportRef, channelRef: channelRef)
        if exited, let remoteSessionID { onRemoteSessionEnded?(remoteSessionID) }
    }
}
