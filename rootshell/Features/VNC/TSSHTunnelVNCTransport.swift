//
//  TSSHTunnelVNCTransport.swift
//  rootshell
//
//  RFBConnection carrying a VNC byte stream over a dedicated headless
//  tssh (tsshd UDP) transport: TrzszHeadlessConnector brings the session
//  up, then a dialTCP gate call opens a TCP channel from the tsshd server
//  to the VNC host. Byte I/O rides the existing stream-local gate calls
//  (nil data + nil error = clean EOF), modeled on TrzszStreamLocalPipe.
//  Created once per connection attempt by the package's transportProvider.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import RFBProtocol
import RFBTransport
import os

/// tssh tunnel transport for a VNC session. One instance per connection
/// attempt; owns its Go transport and dialed channel for its lifetime.
actor TSSHTunnelVNCTransport: RFBConnection {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "TSSHTunnelVNCTransport"
    )

    private let sshConfig: SSHConfig
    private let transportMode: ProfileTransportMode
    private let udpPortMin: Int
    private let udpPortMax: Int
    private let mtu: Int
    private let serverPath: String?
    private let vncHost: String
    private let vncPort: UInt16
    private let onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?

    private var goTransport: TrzszGoTransport?
    private var transportRef: TSSHTransportRef?
    private var channelRef: Int64?
    private var closed = false

    /// Stored for contract completeness. tssh transport death always
    /// surfaces through the session's pending read (the gate read errors
    /// or EOFs when the transport dies), so there is no out-of-band
    /// failure source to wire here.
    private var disconnectHandler: (@Sendable (VNCProtocolError) -> Void)?

    /// - Parameters:
    ///   - sshConfig: Fully resolved bootstrap SSH config (keys resolved,
    ///     saved passwords inlined) for the tsshd spawn.
    ///   - transportMode: Profile transport mode; resolved to KCP/QUIC on
    ///     the main actor at connect time.
    ///   - onHostKeyValidation: Routed to the app's host-key prompt UI for
    ///     the bootstrap SSH connection.
    init(
        sshConfig: SSHConfig,
        transportMode: ProfileTransportMode,
        udpPortMin: Int,
        udpPortMax: Int,
        mtu: Int,
        serverPath: String?,
        vncHost: String,
        vncPort: UInt16,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) {
        self.sshConfig = sshConfig
        self.transportMode = transportMode
        self.udpPortMin = udpPortMin
        self.udpPortMax = udpPortMax
        self.mtu = mtu
        self.serverPath = serverPath
        self.vncHost = vncHost
        self.vncPort = vncPort
        self.onHostKeyValidation = onHostKeyValidation
    }

    // MARK: - RFBConnection

    func connect() async throws {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        guard goTransport == nil else {
            throw VNCProtocolError.ioError("tssh tunnel transport already connected")
        }

        Self.logger.info("Opening tssh tunnel for VNC to \(self.vncHost):\(self.vncPort)")

        let bringUp: (transport: TrzszGoTransport, ref: TSSHTransportRef)
        do {
            bringUp = try await Self.establishTunnel(
                sshConfig: sshConfig,
                transportMode: transportMode,
                udpPortMin: udpPortMin,
                udpPortMax: udpPortMax,
                mtu: mtu,
                serverPath: serverPath,
                onHostKeyValidation: onHostKeyValidation
            )
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.ioError("tssh tunnel failed: \(error.localizedDescription)")
        }

        // close() may have raced the tunnel bring-up.
        if closed {
            await Self.teardown(transport: bringUp.transport)
            throw VNCProtocolError.connectionClosed
        }

        let channel: Int64
        do {
            channel = try await TSSHCallGate.shared.dialTCP(
                on: bringUp.ref,
                host: vncHost,
                port: Int(vncPort)
            )
        } catch {
            await Self.teardown(transport: bringUp.transport)
            throw VNCProtocolError.ioError("VNC dial via tssh failed: \(error.localizedDescription)")
        }

        // And the dial itself.
        if closed {
            try? await TSSHCallGate.shared.streamLocalClose(on: bringUp.ref, channelRef: channel)
            await Self.teardown(transport: bringUp.transport)
            throw VNCProtocolError.connectionClosed
        }

        self.goTransport = bringUp.transport
        self.transportRef = bringUp.ref
        self.channelRef = channel

        Self.logger.info("tssh tunnel established to \(self.vncHost):\(self.vncPort)")
    }

    func read(exactly count: Int) async throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = try await readChunk(maxBytes: count - out.count)
            out.append(chunk)
        }
        return out
    }

    func read(upTo maxCount: Int) async throws -> Data {
        try await readChunk(maxBytes: maxCount)
    }

    func send(_ data: Data) async throws {
        guard !closed, let ref = transportRef, let channelRef else {
            throw VNCProtocolError.connectionClosed
        }
        var remaining = data
        while !remaining.isEmpty {
            let written: Int
            do {
                written = try await TSSHCallGate.shared.streamLocalWrite(
                    on: ref,
                    channelRef: channelRef,
                    data: remaining
                )
            } catch {
                throw closed
                    ? VNCProtocolError.connectionClosed
                    : VNCProtocolError.ioError("tssh tunnel write failed: \(error.localizedDescription)")
            }
            // Zero-progress safety net mirrors TrzszStreamLocalPipe.
            if written <= 0 {
                throw VNCProtocolError.ioError("tssh tunnel write made no progress")
            }
            remaining = remaining.subdata(in: written..<remaining.count)
        }
    }

    func close() async {
        if closed { return }
        closed = true

        let ref = transportRef
        let channel = channelRef
        let transport = goTransport
        transportRef = nil
        channelRef = nil
        goTransport = nil
        disconnectHandler = nil

        // Closing the channel unblocks any parked gate read, which then
        // reports connectionClosed through the read paths above.
        if let ref, let channel {
            try? await TSSHCallGate.shared.streamLocalClose(on: ref, channelRef: channel)
        }
        if let transport {
            await Self.teardown(transport: transport)
        }
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {
        disconnectHandler = handler
    }

    // MARK: - Internal

    private func readChunk(maxBytes: Int) async throws -> Data {
        guard !closed, let ref = transportRef, let channelRef else {
            throw VNCProtocolError.connectionClosed
        }
        let data: Data?
        do {
            data = try await TSSHCallGate.shared.streamLocalRead(
                on: ref,
                channelRef: channelRef,
                maxBytes: maxBytes
            )
        } catch {
            throw closed
                ? VNCProtocolError.connectionClosed
                : VNCProtocolError.ioError("tssh tunnel read failed: \(error.localizedDescription)")
        }
        guard let data, !data.isEmpty else {
            // nil = clean EOF from the Go side.
            throw VNCProtocolError.connectionClosed
        }
        return data
    }

    /// TrzszHeadlessConnector and TrzszGoTransport are MainActor-bound;
    /// hop there for the bring-up and hand back Sendable handles.
    @MainActor
    private static func establishTunnel(
        sshConfig: SSHConfig,
        transportMode: ProfileTransportMode,
        udpPortMin: Int,
        udpPortMax: Int,
        mtu: Int,
        serverPath: String?,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws -> (transport: TrzszGoTransport, ref: TSSHTransportRef) {
        let transport = try await TrzszHeadlessConnector.connect(
            sshConfig: sshConfig,
            transportMode: transportMode.resolved,
            udpPortMin: udpPortMin,
            udpPortMax: udpPortMax,
            mtu: mtu,
            serverPath: serverPath,
            displayName: "vnc \(sshConfig.displayName)",
            onHostKeyValidation: onHostKeyValidation
        )
        guard let ref = transport.activeTransportRef else {
            transport.disconnect()
            throw VNCProtocolError.ioError("tssh transport has no active handle")
        }
        return (transport, ref)
    }

    @MainActor
    private static func teardown(transport: TrzszGoTransport) {
        transport.disconnect()
    }
}
