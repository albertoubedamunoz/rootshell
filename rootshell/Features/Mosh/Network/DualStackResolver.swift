//
//  DualStackResolver.swift
//  rootshell
//
//  Resolves hostnames to both IPv4 and IPv6 addresses for reactive hole-punching
//

import Foundation
import Network
import OSLog

/// Resolves a hostname to both IPv4 and IPv6 addresses
///
/// This enables the reactive hole-punch approach where we can try either
/// address family after server spawn, without being locked to a single family.
///
/// Usage:
/// ```swift
/// let result = try await DualStackResolver.resolve(host: "example.com", port: 60001)
/// // result.ipv4Address might be "192.168.1.1"
/// // result.ipv6Address might be "2001:db8::1"
/// ```
struct DualStackResolver {

    // MARK: - Types

    /// Result of dual-stack resolution
    struct ResolvedAddresses: Sendable {
        /// IPv4 address if available
        let ipv4Address: String?

        /// IPv6 address if available
        let ipv6Address: String?

        /// The original hostname
        let hostname: String

        /// Port for connection
        let port: Int

        /// Whether we have at least one address
        var hasAnyAddress: Bool {
            ipv4Address != nil || ipv6Address != nil
        }

        /// Returns the preferred address (IPv4 first, then IPv6)
        ///
        /// IPv4 is preferred because:
        /// 1. STUN-based NAT traversal is well-tested and reliable for IPv4
        /// 2. IPv6 firewalls can be unpredictable (may block inbound even without NAT)
        /// 3. Most networks have IPv4 connectivity
        /// 4. This keeps STUN and transport in lock-step on the same address family
        var preferredAddress: String? {
            ipv4Address ?? ipv6Address
        }

        /// Returns the preferred address family
        var preferredFamily: AddressFamily {
            if ipv4Address != nil { return .ipv4 }
            if ipv6Address != nil { return .ipv6 }
            return .auto
        }

        /// Returns the alternate address (opposite of preferred)
        var alternateAddress: String? {
            if ipv4Address != nil { return ipv6Address }
            return nil
        }

        /// Returns the alternate address family
        var alternateFamily: AddressFamily? {
            if ipv4Address != nil && ipv6Address != nil { return .ipv6 }
            return nil
        }
    }

    // MARK: - Logger

    private static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "DualStackResolver"
    )

    // MARK: - Resolution

    /// Resolves a hostname to both IPv4 and IPv6 addresses
    /// - Parameters:
    ///   - host: The hostname or IP address to resolve
    ///   - port: The port for the connection
    ///   - timeout: Timeout for resolution (default: 5 seconds)
    /// - Returns: ResolvedAddresses with available addresses
    /// - Throws: If resolution fails completely
    static func resolve(
        host: String,
        port: Int,
        timeout: TimeInterval = 5.0
    ) async throws -> ResolvedAddresses {
        // If already an IP address, detect family and return
        if let family = detectAddressFamily(host) {
            logger.info("Host '\(host)' is already an IP address (\(family.rawValue))")
            switch family {
            case .ipv4:
                return ResolvedAddresses(
                    ipv4Address: host,
                    ipv6Address: nil,
                    hostname: host,
                    port: port
                )
            case .ipv6:
                let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                return ResolvedAddresses(
                    ipv4Address: nil,
                    ipv6Address: cleanHost,
                    hostname: host,
                    port: port
                )
            case .auto:
                // Shouldn't happen, but treat as hostname
                break
            }
        }

        logger.info("Resolving hostname '\(host)' to both IPv4 and IPv6")

        // Resolve both families in parallel
        async let ipv4Result = resolveFamily(host: host, port: port, family: .ipv4, timeout: timeout)
        async let ipv6Result = resolveFamily(host: host, port: port, family: .ipv6, timeout: timeout)

        let (ipv4, ipv6) = await (ipv4Result, ipv6Result)

        logger.info("Resolution complete: IPv4=\(ipv4 ?? "nil"), IPv6=\(ipv6 ?? "nil")")

        // At least one must succeed
        guard ipv4 != nil || ipv6 != nil else {
            throw DualStackResolverError.resolutionFailed(hostname: host)
        }

        return ResolvedAddresses(
            ipv4Address: ipv4,
            ipv6Address: ipv6,
            hostname: host,
            port: port
        )
    }

    // MARK: - Private Methods

    /// Resolves a hostname for a specific address family using DNS (getaddrinfo)
    /// This does not require establishing a connection, so it works for UDP services like Mosh.
    private static func resolveFamily(
        host: String,
        port: Int,
        family: AddressFamily,
        timeout: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_DGRAM  // UDP - appropriate for Mosh

                switch family {
                case .ipv4:
                    hints.ai_family = AF_INET
                case .ipv6:
                    hints.ai_family = AF_INET6
                case .auto:
                    hints.ai_family = AF_UNSPEC
                }

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, String(port), &hints, &result)

                guard status == 0, let addrInfo = result else {
                    continuation.resume(returning: nil)
                    return
                }

                defer { freeaddrinfo(result) }

                // Extract the IP address string from the first result
                let ipString: String?

                if addrInfo.pointee.ai_family == AF_INET {
                    // IPv4
                    var addr = addrInfo.pointee.ai_addr!.withMemoryRebound(
                        to: sockaddr_in.self,
                        capacity: 1
                    ) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    ipString = String(cString: buffer)
                } else if addrInfo.pointee.ai_family == AF_INET6 {
                    // IPv6
                    var addr = addrInfo.pointee.ai_addr!.withMemoryRebound(
                        to: sockaddr_in6.self,
                        capacity: 1
                    ) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    ipString = String(cString: buffer)
                } else {
                    ipString = nil
                }

                continuation.resume(returning: ipString)
            }
        }
    }

    /// Detects if a string is already an IP address and returns its family
    private static func detectAddressFamily(_ host: String) -> AddressFamily? {
        // Check for IPv6 (contains colons)
        if host.contains(":") {
            let cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if cleaned.contains(":") {
                return .ipv6
            }
        }

        // Check for IPv4 (four dot-separated octets)
        let components = host.split(separator: ".")
        if components.count == 4 {
            let allNumeric = components.allSatisfy { component in
                if let num = Int(component), (0...255).contains(num) {
                    return true
                }
                return false
            }
            if allNumeric {
                return .ipv4
            }
        }

        return nil
    }
}

// MARK: - Errors

enum DualStackResolverError: LocalizedError {
    case resolutionFailed(hostname: String)

    var errorDescription: String? {
        switch self {
        case .resolutionFailed(let hostname):
            return "Failed to resolve hostname '\(hostname)' to any IP address"
        }
    }
}
