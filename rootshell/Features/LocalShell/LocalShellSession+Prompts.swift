#if !targetEnvironment(macCatalyst)

import Foundation
import Citadel

private enum PasswordPromptContext {
    case ssh(SSHCommandParser.PartialSSHConfig)
    case scp(SCPParsedCommand, SSHCommandParser.PartialSSHConfig)
    case sftp(SSHCommandParser.PartialSSHConfig)
    case sshCopyID(SSHCopyIDParsedCommand, SSHCommandParser.PartialSSHConfig)

    var partialConfig: SSHCommandParser.PartialSSHConfig {
        switch self {
        case .ssh(let config):
            return config
        case .scp(_, let config):
            return config
        case .sftp(let config):
            return config
        case .sshCopyID(_, let config):
            return config
        }
    }

    var scpCommand: SCPParsedCommand? {
        switch self {
        case .scp(let cmd, _):
            return cmd
        case .ssh, .sftp, .sshCopyID:
            return nil
        }
    }

    var sshCopyIDCommand: SSHCopyIDParsedCommand? {
        switch self {
        case .sshCopyID(let cmd, _):
            return cmd
        case .ssh, .scp, .sftp:
            return nil
        }
    }

    var sessionModeOnSubmit: LocalShellSession.SessionMode {
        switch self {
        case .ssh:
            return .sshSession
        case .scp:
            return .scpTransfer
        case .sftp:
            return .sftpSession
        case .sshCopyID:
            return .sshCopyIDTransfer
        }
    }
}

extension LocalShellSession {
    // MARK: - Password Prompts

    private func currentPasswordPromptContext() -> PasswordPromptContext? {
        switch sessionMode {
        case .passwordPrompt(let config):
            return .ssh(config)
        case .scpPasswordPrompt(let command, let config):
            return .scp(command, config)
        case .sftpPasswordPrompt(let config):
            return .sftp(config)
        case .sshCopyIDPasswordPrompt(let command, let config):
            return .sshCopyID(command, config)
        default:
            return nil
        }
    }

    /// Handle password input character (no echo)
    func handlePasswordInput(_ char: Character) {
        // Handle Mosh password prompt separately
        if case .moshPasswordPrompt(let partialMoshConfig) = sessionMode {
            handleMoshPasswordInput(char, partialConfig: partialMoshConfig)
            return
        }

        // Handle Trzsz password prompt separately
        if case .trzszPasswordPrompt(let partialTrzszConfig) = sessionMode {
            handleTrzszPasswordInput(char, partialConfig: partialTrzszConfig)
            return
        }

        guard let context = currentPasswordPromptContext() else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            // Immediately switch to connecting mode to prevent double-trigger from CRLF
            sessionMode = context.sessionModeOnSubmit

            onOutput?(normalizeLineEndings("\n"))
            let password = passwordBuffer
            passwordBuffer = ""

            // Build full config with password and start session
            let config = context.partialConfig.toSSHConfig(password: password)

            // Store password for potential saving after successful connection
            pendingPasswordToSave = (host: context.partialConfig.host, port: context.partialConfig.port,
                                     username: context.partialConfig.username, password: password)

            Task { @MainActor in
                switch context {
                case .ssh:
                    launchEmbeddedSSHSession(config: config)
                case .sftp:
                    launchEmbeddedSFTPSession(config: config)
                case .scp(let command, _):
                    startSCPTransfer(command: command, config: config)
                case .sshCopyID(let command, _):
                    await startSSHCopyIDTransfer(command: command, config: config)
                }
            }

        case 0x7F, 0x08:  // Backspace
            if !passwordBuffer.isEmpty {
                passwordBuffer.removeLast()
            }

        case 0x03:  // Ctrl-C - cancel
            passwordBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()

        case 0x15:  // Ctrl-U - clear line
            passwordBuffer = ""

        default:
            if char.isASCII && !char.isNewline {
                passwordBuffer.append(char)
                // No echo for password input
            }
        }
    }

    /// Handle Mosh password input character (no echo)
    private func handleMoshPasswordInput(_ char: Character, partialConfig: MoshCommandParser.PartialMoshConfig) {
        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            // Immediately switch to connecting mode to prevent double-trigger from CRLF
            sessionMode = .moshSession

            onOutput?(normalizeLineEndings("\n"))
            let password = passwordBuffer
            passwordBuffer = ""

            // Build full Mosh config with password and start session
            let moshConfig = partialConfig.toMoshConfig(password: password)

            // Store password for potential saving after successful connection
            pendingPasswordToSave = (host: partialConfig.sshPartialConfig.host,
                                     port: partialConfig.sshPartialConfig.port,
                                     username: partialConfig.sshPartialConfig.username,
                                     password: password)

            Task { @MainActor in
                await startEmbeddedMoshSession(config: moshConfig)
            }

        case 0x7F, 0x08:  // Backspace
            if !passwordBuffer.isEmpty {
                passwordBuffer.removeLast()
            }

        case 0x03:  // Ctrl-C - cancel
            passwordBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()

        case 0x15:  // Ctrl-U - clear line
            passwordBuffer = ""

        default:
            if char.isASCII && !char.isNewline {
                passwordBuffer.append(char)
                // No echo for password input
            }
        }
    }

    /// Handle Trzsz password input character (no echo)
    private func handleTrzszPasswordInput(_ char: Character, partialConfig: TrzszCommandParser.PartialTrzszConfig) {
        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            // Immediately switch to connecting mode to prevent double-trigger from CRLF
            sessionMode = .trzszSession

            onOutput?(normalizeLineEndings("\n"))
            let password = passwordBuffer
            passwordBuffer = ""

            // Build full Trzsz config with password and start session
            let trzszConfig = partialConfig.toTrzszConfig(password: password)

            // Store password for potential saving after successful connection
            pendingPasswordToSave = (host: partialConfig.sshPartialConfig.host,
                                     port: partialConfig.sshPartialConfig.port,
                                     username: partialConfig.sshPartialConfig.username,
                                     password: password)

            Task { @MainActor in
                await startEmbeddedTrzszSession(config: trzszConfig, terminalId: terminalId)
            }

        case 0x7F, 0x08:  // Backspace
            if !passwordBuffer.isEmpty {
                passwordBuffer.removeLast()
            }

        case 0x03:  // Ctrl-C - cancel
            passwordBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()

        case 0x15:  // Ctrl-U - clear line
            passwordBuffer = ""

        default:
            if char.isASCII && !char.isNewline {
                passwordBuffer.append(char)
                // No echo for password input
            }
        }
    }

    // MARK: - Git Password Prompt

    /// Handle password input for `git --password` (no echo)
    func handleGitPasswordInput(_ char: Character) {
        guard case .gitPasswordPrompt(let config) = sessionMode else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            onOutput?(normalizeLineEndings("\n"))
            let password = passwordBuffer
            passwordBuffer = ""

            startGitCommand(config: config, command: "git", override: .password(password))

        case 0x7F, 0x08:  // Backspace
            if !passwordBuffer.isEmpty {
                passwordBuffer.removeLast()
            }

        case 0x03:  // Ctrl-C - cancel
            passwordBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()

        case 0x15:  // Ctrl-U - clear line
            passwordBuffer = ""

        default:
            if char.isASCII && !char.isNewline {
                passwordBuffer.append(char)
            }
        }
    }

    /// Handle host key validation input
    func handleHostKeyInput(_ char: Character) {
        guard case .hostKeyPrompt(let continuation) = sessionMode else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            onOutput?(normalizeLineEndings("\n"))
            let response = hostKeyResponseBuffer.lowercased().trimmingCharacters(in: .whitespaces)
            hostKeyResponseBuffer = ""

            let result: HostKeyValidationResult
            switch response {
            case "yes", "y":
                result = .accept
            case "once", "o":
                result = .acceptOnce
            default:
                result = .reject
            }

            sessionMode = .sshSession
            continuation.resume(returning: result)

        case 0x7F, 0x08:  // Backspace
            if !hostKeyResponseBuffer.isEmpty {
                hostKeyResponseBuffer.removeLast()
                // Erase character on screen
                onOutput?("\u{08} \u{08}")
            }

        case 0x03:  // Ctrl-C - reject
            hostKeyResponseBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            continuation.resume(returning: .reject)

        default:
            if char.isASCII && !char.isNewline {
                hostKeyResponseBuffer.append(char)
                // Echo the character
                onOutput?(String(char))
            }
        }
    }

    // MARK: - Save Password Prompt

    /// Prompt the user to save their password after a successful SSH connection
    private func promptToSavePassword(_ pending: (host: String, port: Int, username: String, password: String)) {
        sessionMode = .savePasswordPrompt(host: pending.host, port: pending.port,
                                          username: pending.username, password: pending.password)
        savePasswordResponseBuffer = ""
        let prompt = "\r\nSave password for \(pending.username)@\(pending.host)? (yes/no): "
        onOutput?(normalizeLineEndings(prompt))
    }

    /// Handle input during the save password prompt
    func handleSavePasswordInput(_ char: Character) {
        guard case .savePasswordPrompt(let host, let port, let username, let password) = sessionMode else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            onOutput?(normalizeLineEndings("\n"))
            let response = savePasswordResponseBuffer.lowercased().trimmingCharacters(in: .whitespaces)
            savePasswordResponseBuffer = ""

            if response == "yes" || response == "y" {
                do {
                    try SSHPasswordManager.shared.savePassword(password, host: host, port: port, username: username)
                    onOutput?(normalizeLineEndings("Password saved.\r\n"))
                } catch {
                    onOutput?(normalizeLineEndings("Failed to save password: \(error.localizedDescription)\r\n"))
                }
            }

            sessionMode = .sshSession
            pendingPasswordToSave = nil

        case 0x7F, 0x08:  // Backspace
            if !savePasswordResponseBuffer.isEmpty {
                savePasswordResponseBuffer.removeLast()
                onOutput?("\u{08} \u{08}")
            }

        case 0x03:  // Ctrl-C - skip saving
            savePasswordResponseBuffer = ""
            sessionMode = .sshSession
            pendingPasswordToSave = nil
            onOutput?(normalizeLineEndings("^C\r\n"))

        default:
            if char.isASCII && !char.isNewline {
                savePasswordResponseBuffer.append(char)
                onOutput?(String(char))
            }
        }
    }

    /// Handle host key validation request inline
    func handleHostKeyValidation(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        // Clean up spinner before showing host key prompt
        cleanupInlineSpinner(emitIfEmpty: false)

        // Display the host key prompt
        let promptText: String
        if request.isKeyChanged {
            promptText = "\r\n\u{1B}[1;31mWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\u{1B}[0m\r\n\(request.message)\r\n\r\nAre you sure you want to continue connecting? (yes/no/once): "
        } else {
            promptText = "\r\n\(request.message)\r\n\r\nAre you sure you want to continue connecting? (yes/no/once): "
        }

        onOutput?(normalizeLineEndings(promptText))
        hostKeyResponseBuffer = ""

        // Wait for user input using a continuation
        return await withCheckedContinuation { continuation in
            sessionMode = .hostKeyPrompt(continuation)
        }
    }

    // MARK: - Keyboard-Interactive (RFC 4256) Prompt

    /// Forward a keyboard-interactive challenge from an embedded SSH-style session
    /// (or the rf browser) to the owning terminal view, which presents the shared
    /// SwiftUI prompt sheet — the same UI used for profile/connection-driven
    /// connections. Using the sheet (rather than an inline terminal prompt) keeps
    /// the local shell's `sessionMode` untouched while the embedded connect flow
    /// owns it, and unifies the experience across every launch path.
    func handleKeyboardInteractiveChallenge(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        guard let onChallenge = onKeyboardInteractiveChallenge else { return nil }
        return await onChallenge(challenge)
    }
}

#endif // !targetEnvironment(macCatalyst)
