//
//  FDPassingServer.swift
//  rootshell-helper
//
//  Swift wrapper for FD sender (deprecated - SocketCommandServer calls Objective-C directly)
//

import Foundation

/// Deprecated: Legacy Swift wrapper - not currently used
/// SocketCommandServer now calls FDPassingServerImpl directly
class FDPassingServer {

    /// Sends PTY master FD to Catalyst app via Unix socket
    /// This runs asynchronously in the background
    func sendFileDescriptor(fd: Int32, toSocketPath socketPath: String, completion: @escaping (Bool) -> Void) {
        NSLog("Sending FD to Catalyst app at \(socketPath)")

        // Run in background thread
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FDPassingServerImpl.sendFileDescriptor(
                    fd,
                    toSocketAtPath: socketPath
                )

                // Call completion on main thread
                DispatchQueue.main.async {
                    completion(true)
                }
            } catch {
                NSLog("FD sender error: \(error.localizedDescription)")

                // Call completion on main thread
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
}
