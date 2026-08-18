//
//  EC2ConsoleSession.swift
//  rootshell
//
//  TerminalSession implementation for EC2 Serial Console access.
//  Uses SSH with ephemeral Ed25519 keys for authentication.
//

import Foundation
import os.log
import Combine
import NIOSSH

/// Terminal session that provides serial console access to EC2 instances via SSH
@MainActor
final class EC2ConsoleSession: TerminalSession {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "EC2ConsoleSession")

    // MARK: - Properties

    let pty: TerminalPTY
    let config: EC2ConsoleConfig

    private(set) var isRunning: Bool = false

    /// Current session state
    @Published private(set) var state: EC2ConsoleState = .initial

    /// The underlying SSH session
    private var sshSession: SSHSession?

    /// Ephemeral key for this session
    private var ephemeralKey: EphemeralSSHKey?

    // MARK: - TerminalSession Callbacks
    // NOTE: These callbacks may be called from a background thread (batcher queue).
    // Callers must ensure thread-safe handling.

    var onOutput: (@Sendable (String) -> Void)?
    var onOutputData: (@Sendable (Data) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// Callback for unexpected disconnection (for reconnection support)
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    /// Host-key validation prompt for the serial-console SSH connection.
    /// nil = strict (accept known keys, reject new or changed).
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// Whether this session supports auto-reconnect
    var supportsAutoReconnect: Bool { true }

    /// Delegate to underlying SSH session for connection info
    var connectionInfo: ConnectionInfo? {
        sshSession?.connectionInfo
    }

    /// Flag to track if stop() was called by user action (vs unexpected disconnect)
    private var userInitiatedStop: Bool = false

    /// Additional callback for state changes (for spinner integration)
    var onStateChange: ((EC2ConsoleState) -> Void)?

    // MARK: - Initialization

    init(pty: TerminalPTY, config: EC2ConsoleConfig) {
        self.pty = pty
        self.config = config
    }

    // MARK: - TerminalSession Protocol

    func start() async throws {
        guard !isRunning else { return }

        Self.logger.info("Starting EC2 console session for instance: \(self.config.instanceLabel) (\(self.config.instanceId))")

        do {
            // Phase 1: Generate ephemeral key
            transition(to: .generatingKey)
            let key = EphemeralKeyGenerator.generateEd25519()
            self.ephemeralKey = key
            Self.logger.info("Generated ephemeral Ed25519 key")

            // Phase 2: Upload public key to AWS (starts 60-second validity window)
            transition(to: .uploadingKey)
            try await uploadPublicKey(key.publicKeyOpenSSH)
            Self.logger.info("Uploaded public key to AWS")

            // Phase 3: Connect via SSH (must complete within 60 seconds)
            transition(to: .connectingSSH)
            try await connectSSH(privateKey: key.nioSSHPrivateKey)

            // Phase 4: Running
            isRunning = true
            transition(to: .running)

            // Update title
            onTitleChange?(config.displayName)

            Self.logger.info("EC2 console session ready for instance: \(self.config.instanceLabel)")
            onReady?()

        } catch {
            Self.logger.error("Failed to start EC2 console session: \(error.localizedDescription)")

            let ec2Error: EC2ConsoleError
            if let err = error as? EC2ConsoleError {
                ec2Error = err
            } else if let cloudErr = error as? CloudAPIError {
                ec2Error = mapCloudAPIError(cloudErr)
            } else {
                ec2Error = .connectionFailed(error.localizedDescription)
            }

            transition(to: .failed(ec2Error))
            onError?(ec2Error)

            throw ec2Error
        }
    }

    func stop() {
        Self.logger.info("Stopping EC2 console session")

        // Mark this as user-initiated so we don't trigger reconnection
        userInitiatedStop = true

        let wasRunning = isRunning
        isRunning = false

        // Stop the SSH session
        sshSession?.stop()
        sshSession = nil

        // Clear ephemeral key
        ephemeralKey = nil

        transition(to: .terminated)

        if wasRunning {
            onSessionEnd?()
        }
    }

    func sendInput(_ data: Data) {
        guard isRunning, let sshSession = sshSession else {
            Self.logger.warning("Cannot send input: session not ready")
            return
        }

        sshSession.sendInput(data)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size
        try sshSession?.setSize(size)
    }

    // MARK: - Private Methods

    private func transition(to newState: EC2ConsoleState) {
        state = newState
        onStateChange?(newState)
        Self.logger.info("EC2 console state transition: \(newState.statusDescription)")
    }

    /// Upload ephemeral public key to AWS
    private func uploadPublicKey(_ publicKey: String) async throws {
        Self.logger.info("Uploading public key to AWS for instance: \(self.config.instanceId)")

        // Get account
        guard let account = CloudAccountManager.shared.account(for: config.accountId) else {
            throw EC2ConsoleError.accountNotFound
        }

        // Get credentials
        let credentials: CloudCredentials
        do {
            credentials = try CloudAccountManager.shared.getCredentials(for: account.id)
        } catch {
            throw EC2ConsoleError.credentialsNotFound
        }

        // Create API client
        guard let apiClient = AWSProvider.createAPIClient(credentials: credentials) as? AWSAPIClient else {
            throw EC2ConsoleError.keyUploadFailed("Failed to create AWS API client")
        }

        // Call SendSerialConsoleSSHPublicKey
        do {
            _ = try await apiClient.sendSerialConsoleSSHPublicKey(
                instanceId: config.instanceId,
                region: config.region,
                serialPort: config.serialPort,
                sshPublicKey: publicKey
            )
            Self.logger.info("Public key uploaded successfully")
        } catch let cloudError as CloudAPIError {
            Self.logger.error("Failed to upload public key: \(cloudError.localizedDescription)")
            throw mapCloudAPIError(cloudError)
        } catch {
            Self.logger.error("Failed to upload public key: \(error.localizedDescription)")
            throw EC2ConsoleError.keyUploadFailed(error.localizedDescription)
        }
    }

    /// Connect via SSH using the ephemeral key
    private func connectSSH(privateKey: NIOSSHPrivateKey) async throws {
        Self.logger.info("Connecting SSH to \(self.config.sshHost)")

        // Create SSH config for the serial console
        // We'll use a password placeholder since we're using ephemeral key auth
        let sshConfig = SSHConfig(
            host: config.sshHost,
            port: 22,
            username: config.sshUsername,
            password: "",  // Not used - we'll provide ephemeral key
            cloudInstanceLabel: config.instanceLabel
        )

        // Create SSH session with ephemeral key
        let session = SSHSession(pty: pty, config: sshConfig, ephemeralKey: .nioSSH(privateKey))
        self.sshSession = session

        // Wire up callbacks - capture the callbacks at setup time for thread-safe access
        let outputCallback = self.onOutput
        session.onOutput = { text in
            outputCallback?(text)
        }

        session.onTitleChange = { [weak self] title in
            Task { @MainActor in
                self?.onTitleChange?(title)
            }
        }

        session.onWorkingDirectoryChange = { [weak self] dir in
            Task { @MainActor in
                self?.onWorkingDirectoryChange?(dir)
            }
        }

        session.onBell = { [weak self] in
            Task { @MainActor in
                self?.onBell?()
            }
        }

        session.onSessionEnd = { [weak self] in
            guard let self = self else { return }
            if self.isRunning {
                self.isRunning = false
                self.transition(to: .disconnected(reason: .connectionLost))

                // Check if this was user-initiated or unexpected
                if self.userInitiatedStop {
                    // User-initiated stop - end session normally
                    self.onSessionEnd?()
                } else if let onDisconnect = self.onDisconnect {
                    // Unexpected disconnect - trigger reconnection
                    // Note: EC2 console reconnection will need new ephemeral key
                    onDisconnect(.serverClosed)
                    // Don't call onSessionEnd - let reconnection manager handle it
                } else {
                    // No reconnection handler - fall back to session end
                    self.onSessionEnd?()
                }
            }
        }

        session.onError = { [weak self] error in
            guard let self = self else { return }
            Self.logger.error("SSH session error: \(error.localizedDescription)")
            if self.isRunning {
                self.isRunning = false
                self.transition(to: .failed(.connectionFailed(error.localizedDescription)))
                self.onError?(error)
            }
        }

        // Forward host-key prompts (regional AWS serial-console endpoints
        // prompt once per region); without a prompt, strict-reject.
        session.onHostKeyValidation = { [weak self] request in
            guard let self, let onHostKeyValidation = self.onHostKeyValidation else {
                Self.logger.warning("No host key validation callback set, rejecting serial console key")
                return .reject
            }
            return await onHostKeyValidation(request)
        }

        session.onStateChange = { [weak self] sshState in
            guard let self = self else { return }
            // Map SSH state to EC2 console state
            switch sshState {
            case .connecting:
                self.transition(to: .connectingSSH)
            case .authenticating:
                self.transition(to: .authenticating)
            case .running:
                self.transition(to: .running)
            case .failed:
                // Error will be handled by onError callback
                break
            case .disconnected:
                if self.isRunning {
                    self.transition(to: .disconnected(reason: .connectionLost))
                }
            default:
                break
            }
        }

        // Start the SSH session (this will authenticate with the ephemeral key)
        transition(to: .authenticating)
        try await session.start()
    }

    /// Map CloudAPIError to EC2ConsoleError
    private func mapCloudAPIError(_ error: CloudAPIError) -> EC2ConsoleError {
        switch error {
        case .invalidCredentials:
            return .credentialsNotFound
        case .unauthorized, .forbidden:
            return .serialConsoleNotEnabled
        case .rateLimited:
            return .sessionLimitExceeded
        case .notFound:
            return .instanceNotFound(config.instanceId)
        case .networkError(let err):
            return .networkError(err.localizedDescription)
        default:
            return .keyUploadFailed(error.localizedDescription)
        }
    }
}
