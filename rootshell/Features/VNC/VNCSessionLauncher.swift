//
//  VNCSessionLauncher.swift
//  rootshell
//
//  Maps a VNCConnectionConfig + runtime password into the package's
//  (credentials, configuration) pair, installing a transportProvider for
//  jump connections. Jump specs (profiles, keys, saved passwords) are
//  resolved on the main actor BEFORE the provider closure is built, so
//  the @Sendable closure captures only resolved Sendable values and can
//  run per connection attempt off the main actor.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
import rootshellVNC
import RFBTransport

enum VNCLaunchError: LocalizedError {
    case jumpProfileNotFound
    case jumpKeysUnresolved(String)

    var errorDescription: String? {
        switch self {
        case .jumpProfileNotFound:
            return String(localized: "The jump profile for this Screen Sharing connection no longer exists.")
        case .jumpKeysUnresolved(let names):
            return String(localized: "The jump connection's SSH key is not available on this device (\(names)).")
        }
    }
}

@MainActor
enum VNCSessionLauncher {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VNCSessionLauncher"
    )

    /// Build the credentials + configuration for one VNC session. For a
    /// non-direct `effectiveJump`, installs a `transportProvider` that
    /// creates a fresh tunnel transport per connection attempt.
    static func prepare(
        config: VNCConnectionConfig,
        password: String,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?,
        onCertificateValidation: VNCConfiguration.CertificateValidationHandler?
    ) async throws -> (credentials: VNCCredentials, configuration: VNCConfiguration) {
        let credentials = config.toCredentials(password: password)
        var configuration = config.toPackageConfiguration()
        configuration.certificateValidationHandler = onCertificateValidation

        // High Performance requires direct UDP reachability; effectiveJump
        // already forces .none there, but flag stale persisted combinations.
        if case .none = config.jump {} else if !config.supportsJump {
            assert(config.quality != .adaptive || config.effectiveJump == .none)
            logger.warning("Ignoring jump configuration for High Performance connection")
        }

        switch config.effectiveJump {
        case .none:
            break

        case .sshProfile(let profileID):
            guard let profile = ConnectionProfileManager.shared.profile(for: profileID) else {
                throw VNCLaunchError.jumpProfileNotFound
            }
            let resolved = try await resolveJumpSSHConfig(profile.sshConfig, profileID: profileID)
            configuration.transportProvider = sshProvider(
                config: resolved,
                onHostKeyValidation: onHostKeyValidation
            )

        case .sshConfig(let sshConfig):
            let resolved = try await resolveJumpSSHConfig(sshConfig, profileID: nil)
            configuration.transportProvider = sshProvider(
                config: resolved,
                onHostKeyValidation: onHostKeyValidation
            )

        case .tsshProfile(let profileID):
            guard let profile = ConnectionProfileManager.shared.profile(for: profileID) else {
                throw VNCLaunchError.jumpProfileNotFound
            }
            let resolved = try await resolveJumpSSHConfig(profile.sshConfig, profileID: profileID)
            let transportMode = profile.trzszTransportMode
            let udpPortMin = profile.trzszPortMin ?? TrzszConfig.preferredUDPPortMin
            let udpPortMax = profile.trzszPortMax ?? TrzszConfig.preferredUDPPortMax
            let mtu = profile.trzszMTU ?? 0
            let serverPath = profile.trzszServerPath
            configuration.transportProvider = { host, port in
                TSSHTunnelVNCTransport(
                    sshConfig: resolved,
                    transportMode: transportMode,
                    udpPortMin: udpPortMin,
                    udpPortMax: udpPortMax,
                    mtu: mtu,
                    serverPath: serverPath,
                    vncHost: host,
                    vncPort: port,
                    onHostKeyValidation: onHostKeyValidation
                )
            }
        }

        return (credentials, configuration)
    }

    // MARK: - Jump resolution

    /// Resolve a jump SSH config to a directly connectable one: key UUIDs
    /// via ConnectionKeyResolver (device overrides included), then saved
    /// passwords inlined from the Keychain. Mirrors connectToProfile's
    /// resolve-then-config sequence, minus the interactive fallbacks
    /// (unresolved keys throw instead of opening a resolution sheet).
    private static func resolveJumpSSHConfig(
        _ config: SSHConfig,
        profileID: UUID?
    ) async throws -> SSHConfig {
        var working = config

        switch ConnectionKeyResolver.resolve(config: working, profileID: profileID) {
        case .resolved(let resolved):
            working = resolved
        case .unresolved(_, let unresolvedKeys):
            let ids = unresolvedKeys
                .map { String($0.originalKeyID.uuidString.prefix(8)) }
                .joined(separator: ", ")
            throw VNCLaunchError.jumpKeysUnresolved(ids)
        }

        // Password auth with no inline value: fall back to a stored
        // password when one exists (same as connectToProfile).
        if case .password(let pwd) = working.authMethod, pwd.isEmpty,
           SSHPasswordManager.shared.hasPassword(
               host: working.host, port: working.port, username: working.username
           ) {
            working.authMethod = .savedPassword
        }

        return try await working.resolvedConfig()
    }

    /// Provider closure for the SSH jump. Captures only Sendable resolved
    /// values; runs off the main actor once per connection attempt.
    private static func sshProvider(
        config: SSHConfig,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) -> VNCTransportProvider {
        { host, port in
            SSHTunnelVNCTransport(
                sshConfig: config,
                vncHost: host,
                vncPort: port,
                onHostKeyValidation: onHostKeyValidation
            )
        }
    }
}
