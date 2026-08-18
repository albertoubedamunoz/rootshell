#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import Network
import OSLog
import UIKit

// MARK: - ios_system entry points

/// Entry point for `whatismyip` when invoked via ios_system.
/// Discovers both IPv4 and IPv6 public addresses using STUN (RFC 5389).
@_cdecl("whatismyip_main")
func whatismyip_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return whatismyipIOSSystemEntry(argc: argc, argv: argv, variant: .dual)
}

/// Entry point for `whatismyip4` — IPv4 only.
@_cdecl("whatismyip4_main")
func whatismyip4_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return whatismyipIOSSystemEntry(argc: argc, argv: argv, variant: .ipv4Only)
}

/// Entry point for `whatismyip6` — IPv6 only.
@_cdecl("whatismyip6_main")
func whatismyip6_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return whatismyipIOSSystemEntry(argc: argc, argv: argv, variant: .ipv6Only)
}

// MARK: - Common implementation

private let logger = Logger(subsystem: "com.kk2.rootshell", category: "whatismyip-bridge")

private enum WhatIsMyIPBridgeVariant {
    case dual
    case ipv4Only
    case ipv6Only
}

private func outputStreamForCurrentThread() -> UnsafeMutablePointer<FILE>? {
    if let stream = ios_get_thread_stdout() {
        return stream
    }
    if let stream = ios_get_thread_stderr() {
        return stream
    }
    return Darwin.stdout
}

private func writeToCurrentThreadOutput(_ text: String) {
    guard let stream = outputStreamForCurrentThread() else {
        logger.error("No output stream available for whatismyip ios_system bridge")
        return
    }
    fputs(text, stream)
    fflush(stream)
}

/// Per-server STUN timeout. With 3 IPv4 servers this means 9s worst case.
private let stunTimeout: TimeInterval = 3.0

/// Common entry point for all whatismyip variants invoked via ios_system.
///
/// Bridge pattern: STUNClient/GeoResolver/FaviconManager are @MainActor + async.
/// ios_system calls us on a background thread. We create a pipe pair, dispatch
/// the async work to MainActor with an output closure that writes to the pipe's
/// write-end, then read from the pipe's read-end and write to `ios_get_thread_stdout()`.
/// When the work completes, it closes the write-end → EOF → we return.
private func whatismyipIOSSystemEntry(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    variant: WhatIsMyIPBridgeVariant
) -> Int32 {
    // Parse arguments
    let args = extractArgs(argc: argc, argv: argv)
    let argSet = Set(args.map { $0.lowercased() })

    if argSet.contains("-h") || argSet.contains("--help") {
        writeToCurrentThreadOutput(helpText(for: variant))
        return 0
    }

    let skipASN = argSet.contains("-g")

    // Check for a positional IP address argument
    let positionalArgs = args.filter { !$0.hasPrefix("-") }
    let lookupIP: String? = positionalArgs.first.flatMap { arg in
        if IPv4Address(arg) != nil || IPv6Address(arg) != nil {
            return arg
        }
        return nil
    }

    // If a non-flag positional arg was given but isn't a valid IP, error out
    if let badArg = positionalArgs.first, lookupIP == nil {
        writeToCurrentThreadOutput("whatismyip: invalid IP address '\(badArg)'\n")
        return 1
    }

    // Create a pipe for bridging MainActor output → this thread's stdout
    var pipeFds: [Int32] = [0, 0]
    guard pipe(&pipeFds) == 0 else {
        writeToCurrentThreadOutput("whatismyip: failed to create pipe\n")
        return 1
    }
    let pipeReadFd = pipeFds[0]
    let pipeWriteFd = pipeFds[1]

    guard let threadStdout = outputStreamForCurrentThread() else {
        close(pipeReadFd)
        close(pipeWriteFd)
        logger.error("No output stream available after pipe setup")
        return 1
    }

    // Avoid SIGPIPE termination if the read-end gets closed unexpectedly.
    _ = fcntl(pipeWriteFd, F_SETNOSIGPIPE, 1)

    // Serial queue for pipe writes — keeps writes off MainActor and preserves ordering.
    let writeQueue = DispatchQueue(label: "com.rootshell.whatismyip-bridge.write")
    let writeFd = pipeWriteFd

    nonisolated(unsafe) var exitStatus: Int32 = 0
    nonisolated(unsafe) var writeClosed = false

    // Dispatch async work to MainActor.
    Task { @MainActor in
        let writeText: @Sendable (String) -> Void = { text in
            guard let data = text.data(using: .utf8) else { return }
            writeQueue.async {
                guard !writeClosed else { return }
                data.withUnsafeBytes { buf in
                    guard let ptr = buf.baseAddress else { return }
                    var remaining = buf.count
                    var offset = 0
                    while remaining > 0 {
                        let written = write(writeFd, ptr + offset, remaining)
                        if written < 0 {
                            if errno == EINTR { continue }
                            writeClosed = true
                            break
                        }
                        if written == 0 { break }
                        offset += written
                        remaining -= written
                    }
                }
            }
        }

        var success = false

        if let ip = lookupIP {
            success = await lookupProvidedIP(ip: ip, skipASN: skipASN, output: writeText)
        } else {
            switch variant {
            case .ipv4Only:
                success = await discoverSingleFamily(family: .ipv4, skipASN: skipASN, output: writeText)
            case .ipv6Only:
                success = await discoverSingleFamily(family: .ipv6, skipASN: skipASN, output: writeText)
            case .dual:
                success = await discoverDualStack(skipASN: skipASN, output: writeText)
            }
        }

        // Close write-end after all pending writes drain
        writeQueue.async {
            exitStatus = success ? 0 : 1
            guard !writeClosed else { return }
            writeClosed = true
            close(writeFd)
        }
    }

    // Read loop: pipe read-end → ios_get_thread_stdout()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
        close(pipeReadFd)
    }

    while true {
        let bytesRead = read(pipeReadFd, buffer, bufferSize)
        if bytesRead > 0 {
            fwrite(buffer, 1, bytesRead, threadStdout)
            fflush(threadStdout)
        } else if bytesRead == 0 {
            break
        } else {
            if errno == EINTR { continue }
            break
        }
    }

    return exitStatus
}

// MARK: - IP Lookup (user-provided address)

@MainActor
private func lookupProvidedIP(
    ip: String,
    skipASN: Bool,
    output: @escaping @Sendable (String) -> Void
) async -> Bool {
    output("\(ip)\n")

    if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
        await emitGeoLineWithFavicon(geo, output: output)
    }

    UIPasteboard.general.string = ip
    output("(copied to clipboard)\n")
    return true
}

// MARK: - Discovery

@MainActor
private func discoverSingleFamily(
    family: AddressFamily,
    skipASN: Bool,
    output: @escaping @Sendable (String) -> Void
) async -> Bool {
    if family == .ipv6 && !NetworkReachabilityMonitor.shared.supportsIPv6 {
        output("IPv6: not available on current network\n")
        return false
    }

    let client = STUNClient()
    do {
        let result = try await client.discover(addressFamily: family, timeout: stunTimeout)
        let ip = result.publicIP

        output("\(ip)\n")

        if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
            await emitGeoLineWithFavicon(geo, output: output)
        }

        UIPasteboard.general.string = ip
        output("(copied to clipboard)\n")
        return true
    } catch {
        let label = family == .ipv4 ? "IPv4" : "IPv6"
        output("\(label): failed - \(error.localizedDescription)\n")
        return false
    }
}

@MainActor
private func discoverDualStack(
    skipASN: Bool,
    output: @escaping @Sendable (String) -> Void
) async -> Bool {
    let hasIPv6 = NetworkReachabilityMonitor.shared.supportsIPv6

    var ipv4Result: String?
    var ipv4Error: Error?
    var ipv6Result: String?
    var ipv6Error: Error?

    await withTaskGroup(of: (AddressFamily, String?, Error?).self) { group in
        group.addTask { @MainActor in
            let v4Client = STUNClient()
            do {
                let result = try await v4Client.discover(addressFamily: .ipv4, timeout: stunTimeout)
                return (.ipv4, result.publicIP, nil)
            } catch {
                return (.ipv4, nil, error)
            }
        }
        if hasIPv6 {
            group.addTask { @MainActor in
                let v6Client = STUNClient()
                do {
                    let result = try await v6Client.discover(addressFamily: .ipv6, timeout: stunTimeout)
                    return (.ipv6, result.publicIP, nil)
                } catch {
                    return (.ipv6, nil, error)
                }
            }
        }

        for await (family, ip, error) in group {
            switch family {
            case .ipv4:
                ipv4Result = ip
                ipv4Error = error
            case .ipv6:
                ipv6Result = ip
                ipv6Error = error
            case .auto:
                break
            }
        }
    }

    // IPv4 line
    if let ip = ipv4Result {
        output("IPv4: \(ip)\n")
        if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
            await emitGeoLineWithFavicon(geo, output: output)
        }
    } else if let error = ipv4Error {
        output("IPv4: failed - \(error.localizedDescription)\n")
    }

    // IPv6 line
    if let ip = ipv6Result {
        output("IPv6: \(ip)\n")
        if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
            await emitGeoLineWithFavicon(geo, output: output)
        }
    } else if let error = ipv6Error {
        output("IPv6: failed - \(error.localizedDescription)\n")
    } else if !hasIPv6 {
        output("IPv6: not available\n")
    }

    // Copy successful IPs to clipboard
    let ips = [ipv4Result, ipv6Result].compactMap { $0 }
    if !ips.isEmpty {
        UIPasteboard.general.string = ips.joined(separator: "\n")
        output("(copied to clipboard)\n")
    }

    return ipv4Result != nil || ipv6Result != nil
}

// MARK: - Formatting

@MainActor
private func emitGeoLineWithFavicon(_ geo: GeoInfo, output: @escaping @Sendable (String) -> Void) async {
    let pngData: Data? = if let domain = geo.asDomain, !domain.isEmpty {
        await FaviconManager.shared.favicon(for: domain)
    } else {
        nil
    }

    let geoText = LocalShellSession.formatGeoLineContent(geo)
    output("  ")
    if let pngData {
        LocalShellSession.emitKittyGraphics(pngData: pngData, cols: 2, rows: 1, output: output)
        output(" ")
    }
    output("\(geoText)\n")
}

// MARK: - Helpers

private func extractArgs(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
    let safeArgc = max(0, Int(argc))
    guard safeArgc > 1, let argv else { return [] }

    var args: [String] = []
    args.reserveCapacity(safeArgc - 1)

    for i in 1..<safeArgc {
        if let arg = argv[i], let decoded = String(validatingUTF8: arg) {
            args.append(decoded)
        }
    }

    return args
}

private func helpText(for variant: WhatIsMyIPBridgeVariant) -> String {
    switch variant {
    case .dual:
        return """
            usage: whatismyip [-g] [<ip>]

            Discover your public IPv4 and IPv6 addresses using STUN (RFC 5389).
            Displays ASN, CIDR, and country info for each address.
            Both addresses are copied to the clipboard.
            IPv6 is skipped automatically if unavailable on the current network.

            If <ip> is given, skips STUN discovery and looks up info for that address instead.

            Options:
              -g          Skip ASN/geo lookup (IP address only)

            """
    case .ipv4Only:
        return """
            usage: whatismyip4 [-g] [<ip>]

            Discover your public IPv4 address using STUN (RFC 5389).
            Displays ASN, CIDR, and country info.
            The address is copied to the clipboard.

            If <ip> is given, skips STUN discovery and looks up info for that address instead.

            Options:
              -g          Skip ASN/geo lookup (IP address only)

            """
    case .ipv6Only:
        return """
            usage: whatismyip6 [-g] [<ip>]

            Discover your public IPv6 address using STUN (RFC 5389).
            Displays ASN, CIDR, and country info.
            The address is copied to the clipboard.
            Reports immediately if IPv6 is not available on the current network.

            If <ip> is given, skips STUN discovery and looks up info for that address instead.

            Options:
              -g          Skip ASN/geo lookup (IP address only)

            """
    }
}

#endif // !targetEnvironment(macCatalyst)
