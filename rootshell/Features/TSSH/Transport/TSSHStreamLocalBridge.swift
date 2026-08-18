//
//  TSSHStreamLocalBridge.swift
//  rootshell
//
//  Bridges Go's `StreamLocalCallback` interface to ``GPGAgentManager``.
//  For each accepted Unix-socket connection delivered by TSSHD's
//  remote-listen mechanism, this bridge wraps the opaque Go channel
//  reference in an ``AsyncBytePipe`` and hands it to
//  ``GPGAgentManager/serve(stream:)`` — the same entry point the
//  Citadel transport uses, so the Assuan / signing logic stays one
//  source of truth across transports.
//
//  Lifecycle mirrors ``TrzszAgentBridge``: the Go callback method runs
//  on a goroutine, we hop to MainActor to instantiate Swift state, and
//  the per-channel `serve(...)` loop owns the read/write/close calls
//  back through ``TSSHCallGate``.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
@preconcurrency import TrzszSSH

/// Receives forwarded GPG-agent (or generic Unix-socket) channels from
/// the TSSHD UDP transport and feeds them to ``GPGAgentManager``.
///
/// One bridge instance per active forward (per remote socket path).
/// Lifetime is bounded by ``TrzszSession`` — when the session
/// disconnects, the bridge is torn down by calling
/// ``TSSHCallGate/disableStreamLocalForwarding(on:remotePath:)``,
/// which stops the Go-side accept loop and closes any remaining
/// channels.
nonisolated final class TrzszStreamLocalBridge: NSObject,
    IosbridgeStreamLocalCallbackProtocol, @unchecked Sendable {

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszStreamLocalBridge"
    )

    private let gpgAgentManager: GPGAgentManager
    private let transportRef: TSSHTransportRef

    init(gpgAgentManager: GPGAgentManager, transportRef: TSSHTransportRef) {
        self.gpgAgentManager = gpgAgentManager
        self.transportRef = transportRef
        super.init()
    }

    // MARK: - IosbridgeStreamLocalCallbackProtocol

    /// Called per accepted connection from a Go goroutine. Hops to
    /// MainActor, builds an ``AsyncBytePipe`` adapter that drives byte
    /// I/O through ``TSSHCallGate``, and starts the Assuan server.
    func onAccept(_ channelRef: Int64) {
        let manager = self.gpgAgentManager
        let pipe = TrzszStreamLocalPipe(
            channelRef: channelRef,
            transportRef: self.transportRef
        )
        Task { @MainActor in
            await manager.serve(stream: pipe)
        }
    }

    func onError(_ message: String?) {
        let msg = message ?? "<no message>"
        Self.logger.warning("streamlocal listener error: \(msg)")
    }
}

// MARK: - AsyncBytePipe adapter

/// Concrete ``AsyncBytePipe`` that pumps bytes through the Go-side
/// channel handle table via ``TSSHCallGate``. The reference is opaque
/// — the Go side resolves it back to a `net.Conn` per call. All
/// reads/writes flow through the gate's serial executor so they don't
/// race with each other or with unrelated transport operations.
private nonisolated final class TrzszStreamLocalPipe: AsyncBytePipe, @unchecked Sendable {

    private let channelRef: Int64
    private let transportRef: TSSHTransportRef

    init(channelRef: Int64, transportRef: TSSHTransportRef) {
        self.channelRef = channelRef
        self.transportRef = transportRef
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await TSSHCallGate.shared.streamLocalRead(
            on: transportRef,
            channelRef: channelRef,
            maxBytes: maxBytes
        )
    }

    func write(_ data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = try await TSSHCallGate.shared.streamLocalWrite(
                on: transportRef,
                channelRef: channelRef,
                data: remaining
            )
            // Zero-progress safety net — without it a buggy peer could
            // wedge the Assuan loop.
            if written <= 0 {
                throw NSError(
                    domain: "TrzszStreamLocalPipe",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "streamlocal write made no progress"]
                )
            }
            remaining = remaining.subdata(in: written..<remaining.count)
        }
    }

    func close() async {
        try? await TSSHCallGate.shared.streamLocalClose(
            on: transportRef,
            channelRef: channelRef
        )
    }
}
