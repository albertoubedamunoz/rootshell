//
//  SocketHelperConnection.swift
//  rootshell
//
//  Socket-based connection to ghostty-helper.
//  Replaces XPC which is not available on Mac Catalyst.
//

import Foundation

/// Socket-based connection to ghostty-helper
/// Communicates over a Unix domain socket in the App Group container.
@available(macCatalyst 14.0, *)
class SocketHelperConnection {

    private static let ioQueue = DispatchQueue(label: "com.rootshell.helper.socket", qos: .userInitiated)

    // MARK: - Public Interface

    /// Creates a new shell session
    func createShell(
        rows: UInt16,
        cols: UInt16,
        cwd: String?,
        shell: String?,
        resourcesDir: String? = nil,
        enableShellIntegration: Bool = true,
        sshAuthSock: String? = nil
    ) async throws -> (sessionID: UUID, socketPath: String) {
        let request = CreateShellRequest(
            rows: rows,
            cols: cols,
            cwd: cwd,
            shell: shell,
            resourcesDir: resourcesDir,
            enableShellIntegration: enableShellIntegration,
            sshAuthSock: sshAuthSock,
            appVersion: TerminalIdentity.shortVersion,
            appVersionWithBuild: TerminalIdentity.version,
            termType: TerminalTypeSettings.local
        )
        let payload = try JSONEncoder().encode(request)

        let response = try await sendCommand(.createShell, payload: payload)

        guard let responsePayload = response.payload else {
            throw SocketHelperError.missingResponseData
        }

        let createResponse = try JSONDecoder().decode(CreateShellResponse.self, from: responsePayload)
        return (createResponse.sessionID, createResponse.socketPath)
    }

    /// Resizes an existing shell session
    func resizeShell(sessionID: UUID, rows: UInt16, cols: UInt16) async throws {
        let request = ResizeShellRequest(sessionID: sessionID, rows: rows, cols: cols)
        let payload = try JSONEncoder().encode(request)

        _ = try await sendCommand(.resizeShell, payload: payload)
    }

    /// Kills an existing shell session
    func killShell(sessionID: UUID) async throws {
        let request = KillShellRequest(sessionID: sessionID)
        let payload = try JSONEncoder().encode(request)

        _ = try await sendCommand(.killShell, payload: payload)
    }

    /// Checks if helper is available
    func ping() async throws {
        _ = try await sendCommand(.ping)
    }

    /// Executes a command with streaming output
    /// - Parameters:
    ///   - command: Shell command to execute
    ///   - cwd: Working directory (nil = use default)
    ///   - timeout: Maximum execution time in seconds (nil = 30s default)
    ///   - onOutput: Called with each output chunk (data, isStderr)
    /// - Returns: Final result with exit code and timing
    func executeCommand(
        command: String,
        cwd: String?,
        timeout: TimeInterval?,
        onOutput: @escaping (Data, Bool) -> Void
    ) async throws -> ExecuteCommandResult {
        guard let socketPath = AppGroupHelper.commandSocketPath else {
            throw SocketHelperError.noAppGroupContainer
        }

        let request = ExecuteCommandRequest(
            command: command,
            workingDirectory: cwd,
            timeout: timeout,
            environment: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    let result = try Self.executeCommandSync(
                        socketPath: socketPath,
                        request: request,
                        onOutput: onOutput
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous implementation of executeCommand with streaming
    private static func executeCommandSync(
        socketPath: String,
        request: ExecuteCommandRequest,
        onOutput: @escaping (Data, Bool) -> Void
    ) throws -> ExecuteCommandResult {
        // Create socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw SocketHelperError.socketCreationFailed(errno)
        }

        defer {
            close(sock)
        }

        // Connect to helper
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, pathLength)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sock, sockaddrPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            throw SocketHelperError.connectionFailed(errno)
        }

        // Send request
        let payload = try JSONEncoder().encode(request)
        let socketRequest = SocketRequest(command: .executeCommand, payload: payload)
        let requestData = try SocketMessage.encode(socketRequest)
        try SocketMessage.write(requestData, to: sock)

        // Read streaming responses until completion
        var accumulatedOutput = Data()

        while true {
            let responseData = try SocketMessage.read(from: sock)
            let response = try SocketMessage.decode(responseData, as: SocketResponse.self)

            // Check for error
            if !response.success {
                throw SocketHelperError.commandFailed(response.error ?? "Unknown error")
            }

            guard let payload = response.payload else {
                throw SocketHelperError.missingResponseData
            }

            // Check if this is the completion message (error field == "complete")
            if response.error == "complete" {
                let complete = try JSONDecoder().decode(ExecuteComplete.self, from: payload)

                // Convert accumulated data to string
                let outputString = String(decoding: accumulatedOutput, as: UTF8.self)

                return ExecuteCommandResult(
                    output: outputString,
                    exitCode: complete.exitCode,
                    timedOut: complete.timedOut,
                    duration: complete.duration
                )
            }

            // This is an output chunk
            let chunk = try JSONDecoder().decode(ExecuteOutputChunk.self, from: payload)
            accumulatedOutput.append(chunk.data)
            onOutput(chunk.data, chunk.isStderr)
        }
    }

    // MARK: - Private Implementation

    private func sendCommand(_ command: SocketCommand, payload: Data? = nil) async throws -> SocketResponse {
        guard let socketPath = AppGroupHelper.commandSocketPath else {
            throw SocketHelperError.noAppGroupContainer
        }

        let payload = payload
        return try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
            do {
                let response = try Self.sendCommandSync(socketPath: socketPath, command: command, payload: payload)
                if let helperPID = response.helperPID {
                    #if STANDALONE
                    HelperConnection.recordHelperProcessID(helperPID)
                    #endif
                }
                continuation.resume(returning: response)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        }
    }

    private static func sendCommandSync(socketPath: String, command: SocketCommand, payload: Data?) throws -> SocketResponse {
        // Create socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw SocketHelperError.socketCreationFailed(errno)
        }

        defer {
            close(sock)
        }

        // Connect to helper
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, pathLength)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sock, sockaddrPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            throw SocketHelperError.connectionFailed(errno)
        }

        // Send request
        let request = SocketRequest(command: command, payload: payload)
        let requestData = try SocketMessage.encode(request)
        try SocketMessage.write(requestData, to: sock)

        // Read response
        let responseData = try SocketMessage.read(from: sock)
        let response = try SocketMessage.decode(responseData, as: SocketResponse.self)

        // Check for errors
        guard response.success else {
            throw SocketHelperError.commandFailed(response.error ?? "Unknown error")
        }

        return response
    }
}

// MARK: - Errors

enum SocketHelperError: Error, LocalizedError {
    case noAppGroupContainer
    case socketCreationFailed(Int32)
    case connectionFailed(Int32)
    case commandFailed(String)
    case missingResponseData

    var errorDescription: String? {
        switch self {
        case .noAppGroupContainer:
            return "App Group container not accessible"
        case .socketCreationFailed(let errno):
            return "Failed to create socket: \(String(cString: strerror(errno)))"
        case .connectionFailed(let errno):
            return "Failed to connect to helper: \(String(cString: strerror(errno)))"
        case .commandFailed(let message):
            return "Command failed: \(message)"
        case .missingResponseData:
            return "Response missing expected data"
        }
    }
}
