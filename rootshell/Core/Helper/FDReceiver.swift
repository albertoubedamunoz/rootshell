//
//  FDReceiver.swift
//  rootshell
//
//  Swift wrapper for FD receiver
//  Only available on Mac Catalyst
//

import Foundation
import os

#if targetEnvironment(macCatalyst)

/// Server-side FD receiver (used by Catalyst app)
/// Creates a socket server and waits for helper to connect
class FDReceiver {

    /// Creates a server socket and receives a file descriptor from the helper
    /// - Parameters:
    ///   - socketPath: Path to Unix domain socket to create
    /// - Returns: The received file descriptor, or nil on failure
    static func receiveFileDescriptor(from socketPath: String) -> Int32? {
        var error: NSError?
        let fd = FDReceiverImpl.receiveFileDescriptor(
            asServer: socketPath,
            error: &error
        )

        if let error = error {
            Ghostty.logger.error("FD receiver error: \(error.localizedDescription)")
            return nil
        }

        if fd < 0 {
            return nil
        }

        return fd
    }
}

#endif // targetEnvironment(macCatalyst)
