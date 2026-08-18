#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import OSLog

/// UDP multicast peer discovery for LAN transfers.
/// Wire-compatible with Go croc's use of the `peerdiscovery` library:
/// UDP port 9999, IPv4 group 239.255.255.250 plus IPv6 group ff02::c,
/// multicast hop limit 2, raw unframed payloads.
///
/// Discovery is symmetric — every peer multicasts its payload every 20ms
/// and listens on the same group. Sender payload = "croc" + relay port
/// (30s limit unless local-only); receiver payload = "ok" (presence beacon,
/// ignored by the sender). The receiver returns the first "croc"-prefixed
/// payload from a non-self source within the 200ms window.
///
/// Implemented with BSD sockets, like peerdiscovery itself. NWConnectionGroup
/// is unusable here: its internal multicast listener ignores
/// allowLocalEndpointReuse and keeps :9999 bound after cancel(), so every
/// group created after the first send in a process fails with EADDRINUSE.
/// BSD sockets give explicit SO_REUSEPORT, per-interface group joins and
/// send fan-out (IP_MULTICAST_IF), and immediate port release on close().
///
/// Requires `com.apple.developer.networking.multicast` entitlement on iOS
/// (the entitlement covers BSD sockets the same as Network.framework).
/// Falls back gracefully if entitlement is unavailable.
nonisolated enum CrocPeerDiscovery {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocPeerDiscovery")

    struct DiscoveredPeer: Sendable {
        let address: String
        let payload: String
    }

    // MARK: - Interface Enumeration

    private struct MulticastInterface {
        let name: String
        let index: UInt32
        let ipv4: in_addr?
        let hasIPv6: Bool
    }

    /// Interfaces eligible for discovery: loopback, or up and
    /// multicast-capable. Mirrors peerdiscovery's filterInterfaces.
    private static func multicastInterfaces() -> [MulticastInterface] {
        struct Accumulator {
            var index: UInt32
            var ipv4: in_addr?
            var hasIPv6 = false
        }
        var byName: [String: Accumulator] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            let eligible = (flags & UInt32(IFF_LOOPBACK)) != 0
                || ((flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_MULTICAST)) != 0)
            guard eligible, let sa = current.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var entry = byName[name] ?? Accumulator(index: if_nametoindex(name))
            if family == AF_INET, entry.ipv4 == nil {
                var sin = sockaddr_in()
                withUnsafeMutableBytes(of: &sin) { dst in
                    let length = min(Int(sa.pointee.sa_len), MemoryLayout<sockaddr_in>.size)
                    dst.copyBytes(from: UnsafeRawBufferPointer(start: sa, count: length))
                }
                entry.ipv4 = sin.sin_addr
            } else if family == AF_INET6 {
                entry.hasIPv6 = true
            }
            byName[name] = entry
        }
        return byName.map {
            MulticastInterface(name: $0.key, index: $0.value.index, ipv4: $0.value.ipv4, hasIPv6: $0.value.hasIPv6)
        }
    }

    // MARK: - Sockets

    /// One UDP socket bound to :9999 with the group joined on every
    /// eligible interface. Sends fan out once per interface, like
    /// peerdiscovery's broadcast().
    private final class MulticastSocket: @unchecked Sendable {
        let fd: Int32
        let isIPv6: Bool
        private let sendInterfaces: [MulticastInterface]
        private let destination: sockaddr_storage
        private let destinationLength: socklen_t
        private let lock = NSLock()
        private var loggedSendError = false
        private var closed = false

        init(
            fd: Int32,
            isIPv6: Bool,
            sendInterfaces: [MulticastInterface],
            destination: sockaddr_storage,
            destinationLength: socklen_t
        ) {
            self.fd = fd
            self.isIPv6 = isIPv6
            self.sendInterfaces = sendInterfaces
            self.destination = destination
            self.destinationLength = destinationLength
        }

        /// Send the payload once per joined interface.
        func sendToAll(_ payload: Data) {
            for iface in sendInterfaces {
                if isIPv6 {
                    var index = iface.index
                    _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                } else if var addr = iface.ipv4 {
                    _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
                } else {
                    continue
                }

                var dest = destination
                if isIPv6 {
                    withUnsafeMutablePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                            sin6.pointee.sin6_scope_id = iface.index
                        }
                    }
                }
                let destLen = destinationLength
                let sent = payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                    withUnsafePointer(to: dest) { destPtr in
                        destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, buf.baseAddress, buf.count, 0, sa, destLen)
                        }
                    }
                }
                if sent < 0 {
                    logSendErrorOnce(errno, interface: iface.name)
                }
            }
        }

        private func logSendErrorOnce(_ err: Int32, interface: String) {
            let shouldLog = lock.withLock {
                guard !loggedSendError else { return false }
                loggedSendError = true
                return true
            }
            guard shouldLog else { return }
            let message = String(cString: strerror(err))
            logger.info("Multicast send failing on \(interface): \(message)")
        }

        func close() {
            lock.withLock {
                guard !closed else { return }
                closed = true
                _ = Darwin.close(fd)
            }
        }
    }

    private static func bindSocket(_ fd: Int32, _ addr: inout sockaddr_in) -> Bool {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func bindSocket(_ fd: Int32, _ addr: inout sockaddr_in6) -> Bool {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }

    private static func openIPv4Socket(group: String, interfaces: [MulticastInterface]) -> MulticastSocket? {
        var groupAddr = in_addr()
        guard inet_pton(AF_INET, group, &groupAddr) == 1 else {
            logger.error("Invalid multicast address: \(group)")
            return nil
        }
        let candidates = interfaces.filter { $0.ipv4 != nil }
        guard !candidates.isEmpty else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to the group address like Go's ListenPacket("udp4", group:port);
        // fall back to INADDR_ANY (the "croc" prefix filter handles unicast noise).
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = CrocConstants.discoveryPort.bigEndian
        bindAddr.sin_addr = groupAddr
        var bound = bindSocket(fd, &bindAddr)
        if !bound {
            bindAddr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_ANY))
            bound = bindSocket(fd, &bindAddr)
        }
        guard bound else {
            let message = String(cString: strerror(errno))
            logger.error("IPv4 discovery bind failed: \(message)")
            Darwin.close(fd)
            return nil
        }

        var joined: [MulticastInterface] = []
        for iface in candidates {
            guard let ipv4 = iface.ipv4 else { continue }
            var mreq = ip_mreq(imr_multiaddr: groupAddr, imr_interface: ipv4)
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joined.append(iface)
            }
        }
        guard !joined.isEmpty else {
            let message = String(cString: strerror(errno))
            logger.error("IPv4 multicast join failed on all interfaces (entitlement or Local Network permission missing?): \(message)")
            Darwin.close(fd)
            return nil
        }

        var ttl: UInt8 = 2
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var dest = sockaddr_storage()
        withUnsafeMutablePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                sin.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.pointee.sin_family = sa_family_t(AF_INET)
                sin.pointee.sin_port = CrocConstants.discoveryPort.bigEndian
                sin.pointee.sin_addr = groupAddr
            }
        }

        let joinedNames = joined.map(\.name).joined(separator: ",")
        logger.info("IPv4 discovery joined \(group) on [\(joinedNames)]")
        return MulticastSocket(
            fd: fd,
            isIPv6: false,
            sendInterfaces: joined,
            destination: dest,
            destinationLength: socklen_t(MemoryLayout<sockaddr_in>.size)
        )
    }

    private static func openIPv6Socket(interfaces: [MulticastInterface]) -> MulticastSocket? {
        var groupAddr = in6_addr()
        guard inet_pton(AF_INET6, CrocConstants.defaultMulticastAddress6, &groupAddr) == 1 else { return nil }
        let candidates = interfaces.filter { $0.hasIPv6 && $0.index != 0 }
        guard !candidates.isEmpty else { return nil }

        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in6()
        bindAddr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        bindAddr.sin6_family = sa_family_t(AF_INET6)
        bindAddr.sin6_port = CrocConstants.discoveryPort.bigEndian
        bindAddr.sin6_addr = in6addr_any
        guard bindSocket(fd, &bindAddr) else {
            let message = String(cString: strerror(errno))
            logger.info("IPv6 discovery bind failed: \(message)")
            Darwin.close(fd)
            return nil
        }

        var joined: [MulticastInterface] = []
        for iface in candidates {
            var mreq = ipv6_mreq(ipv6mr_multiaddr: groupAddr, ipv6mr_interface: iface.index)
            if setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, socklen_t(MemoryLayout<ipv6_mreq>.size)) == 0 {
                joined.append(iface)
            }
        }
        guard !joined.isEmpty else {
            // IPv6 is best-effort; IPv4 carries discovery on most networks
            logger.info("IPv6 multicast join failed on all interfaces")
            Darwin.close(fd)
            return nil
        }

        var hops: Int32 = 2
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var dest = sockaddr_storage()
        withUnsafeMutablePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                sin6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sin6.pointee.sin6_family = sa_family_t(AF_INET6)
                sin6.pointee.sin6_port = CrocConstants.discoveryPort.bigEndian
                sin6.pointee.sin6_addr = groupAddr
            }
        }

        let joinedNames = joined.map(\.name).joined(separator: ",")
        let group = CrocConstants.defaultMulticastAddress6
        logger.info("IPv6 discovery joined \(group) on [\(joinedNames)]")
        return MulticastSocket(
            fd: fd,
            isIPv6: true,
            sendInterfaces: joined,
            destination: dest,
            destinationLength: socklen_t(MemoryLayout<sockaddr_in6>.size)
        )
    }

    private static func openSockets(multicastAddress: String) -> [MulticastSocket] {
        let interfaces = multicastInterfaces()
        guard !interfaces.isEmpty else {
            logger.error("No multicast-capable interfaces available")
            return []
        }
        var sockets: [MulticastSocket] = []
        if let v4 = openIPv4Socket(group: multicastAddress, interfaces: interfaces) {
            sockets.append(v4)
        }
        if let v6 = openIPv6Socket(interfaces: interfaces) {
            sockets.append(v6)
        }
        return sockets
    }

    // MARK: - Receive

    private static func receiveOne(from socket: MulticastSocket) -> (payload: Data, address: String)? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var source = sockaddr_storage()
        var sourceLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &source) { srcPtr in
            srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(socket.fd, &buffer, buffer.count, 0, sa, &sourceLen)
            }
        }
        guard count > 0 else { return nil }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameOK = withUnsafePointer(to: source) { srcPtr in
            srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, sourceLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0
            }
        }
        guard nameOK else { return nil }
        return (Data(buffer[0..<count]), String(cString: hostname))
    }

    // MARK: - Sender: Broadcast Presence

    /// Broadcast presence on the local network for peer discovery.
    /// Multicasts "croc" + port every 20ms until stopped, cancelled, or
    /// `timeLimit` elapses (nil = no limit, matching --local).
    /// Returns a cancellation handle.
    static func startBroadcasting(
        port: String,
        multicastAddress: String = CrocConstants.defaultMulticastAddress,
        timeLimit: TimeInterval? = nil,
        stopSignal: @Sendable @escaping () -> Bool
    ) -> Task<Void, Never> {
        return Task.detached {
            let payload = Data("croc\(port)".utf8)
            let sockets = openSockets(multicastAddress: multicastAddress)
            guard !sockets.isEmpty else {
                logger.error("Multicast broadcast unavailable (entitlement may be missing)")
                return
            }
            defer { for socket in sockets { socket.close() } }

            let deadline = timeLimit.map { Date(timeIntervalSinceNow: $0) }
            while !stopSignal() && !Task.isCancelled {
                if let deadline, Date() >= deadline { break }
                for socket in sockets { socket.sendToAll(payload) }
                try? await Task.sleep(for: .seconds(CrocConstants.discoveryDelay))
            }
        }
    }

    // MARK: - Receiver: Discover Peers

    /// Discover peers on the local network.
    /// Listens on IPv4 + IPv6 groups while multicasting an "ok" presence
    /// beacon. Returns the first "croc"-prefixed payload from a non-self
    /// source within the timeout, or nil.
    static func discover(
        multicastAddress: String = CrocConstants.defaultMulticastAddress,
        timeout: TimeInterval = CrocConstants.discoveryTimeout
    ) async -> DiscoveredPeer? {
        await Task.detached {
            blockingDiscover(multicastAddress: multicastAddress, timeout: timeout)
        }.value
    }

    private static func blockingDiscover(multicastAddress: String, timeout: TimeInterval) -> DiscoveredPeer? {
        let sockets = openSockets(multicastAddress: multicastAddress)
        guard !sockets.isEmpty else {
            logger.error("Multicast discovery unavailable (entitlement may be missing)")
            return nil
        }
        defer { for socket in sockets { socket.close() } }

        let localAddresses = CrocFileUtils.getAllLocalAddresses()
        let beacon = Data("ok".utf8)
        let deadline = Date(timeIntervalSinceNow: timeout)
        var nextBeacon = Date()
        var pollFDs = sockets.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }

        while Date() < deadline {
            // Presence beacon: multicast "ok" every 20ms during the window
            if Date() >= nextBeacon {
                for socket in sockets { socket.sendToAll(beacon) }
                nextBeacon = Date(timeIntervalSinceNow: CrocConstants.discoveryDelay)
            }

            let wait = min(deadline.timeIntervalSinceNow, nextBeacon.timeIntervalSinceNow)
            let waitMs = Int32(max(1, Int((wait * 1000).rounded(.up))))
            let ready = poll(&pollFDs, nfds_t(pollFDs.count), waitMs)
            guard ready > 0 else { continue }

            for index in pollFDs.indices where pollFDs[index].revents & Int16(POLLIN) != 0 {
                pollFDs[index].revents = 0
                while let (payload, address) = receiveOne(from: sockets[index]) {
                    // Ignore our own beacons (peerdiscovery's self-filter)
                    let unscoped = address.split(separator: "%").first.map(String.init) ?? address
                    if localAddresses.contains(address) || localAddresses.contains(unscoped) { continue }

                    // Only accept croc discovery payloads
                    guard let text = String(data: payload, encoding: .utf8), text.hasPrefix("croc") else { continue }
                    return DiscoveredPeer(address: address, payload: text)
                }
            }
        }
        return nil
    }
}

#endif
