//
//  TSSHHeadlessConnector.swift
//  rootshell
//
//  Headless tssh session bring-up shared by BackgroundTunnel (port
//  forwarding) and TSSHTunnelVNCTransport (Screen Sharing tunnels):
//  resolve the host, spawn tsshd over a bootstrap SSH connection, connect
//  the Go transport, then close the bootstrap SSH clients. No PTY session
//  stream is opened; callers drive the transport through gate calls
//  (port forwards, dialTCP) instead.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
@preconcurrency import Citadel
import os.log

@MainActor
enum TrzszHeadlessConnector {

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszHeadlessConnector"
    )

    /// Spawns tsshd and returns a connected `TrzszGoTransport` with no
    /// session stream. The bootstrap SSH clients are always closed before
    /// returning (on success and on failure).
    static func connect(
        sshConfig: SSHConfig,
        transportMode: TrzszConfig.TransportMode,
        udpPortMin: Int,
        udpPortMax: Int,
        mtu: Int,
        serverPath: String? = nil,
        displayName: String,
        onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws -> TrzszGoTransport {
        let trzszConfig = TrzszConfig(
            sshConfig: sshConfig,
            transportMode: transportMode,
            udpPortMin: udpPortMin,
            udpPortMax: udpPortMax,
            serverPath: serverPath,
            mtu: mtu
        )

        // Resolve hostname
        let resolved = try await DualStackResolver.resolve(host: sshConfig.host, port: 0)
        let connectionHost = resolved.preferredAddress ?? sshConfig.host
        logger.info("TSSH: Resolved address: \(connectionHost)")

        // Spawn tsshd via SSH
        let spawnResult = try await TrzszSpawnHelper.spawnTsshd(
            config: trzszConfig,
            resolvedHost: connectionHost,
            onHostKeyValidation: onHostKeyValidation
        )

        logger.info("TSSH: tsshd spawned on port \(spawnResult.serverInfo.port), mode=\(spawnResult.serverInfo.mode.rawValue)")

        // Connect Go transport (no session stream needed for headless use)
        // Use do/catch to ensure SSH clients are closed even if transport setup fails
        let transport: TrzszGoTransport
        do {
            transport = try TrzszGoTransport(
                host: connectionHost,
                port: spawnResult.serverInfo.port,
                serverInfo: spawnResult.serverInfo,
                mtu: trzszConfig.mtu,
                displayName: displayName,
                terminalType: trzszConfig.sshConfig.effectiveTerminalType
            )
            try await transport.connect()
        } catch {
            try? await spawnResult.sshClient.close()
            if let jumpClient = spawnResult.jumpClient {
                try? await jumpClient.close()
            }
            throw error
        }

        // Transport connected — safe to close SSH spawn clients
        try? await spawnResult.sshClient.close()
        if let jumpClient = spawnResult.jumpClient {
            try? await jumpClient.close()
        }

        return transport
    }
}
