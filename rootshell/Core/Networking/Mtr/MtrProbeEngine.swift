#if !targetEnvironment(macCatalyst)

import Foundation
import Darwin
import OSLog

// IPv6 socket option constants not exposed to Swift on iOS
private let kIPV6_RECVHOPLIMIT: Int32 = 37
private let kIPV6_2292HOPLIMIT: Int32 = 20
private let kIPV6_HOPLIMIT: Int32 = 47
private let kSCM_TIMESTAMP: Int32 = 2

/// ICMP probe engine for mtr - sends probes at varying TTLs and parses
/// both Echo Reply and Time Exceeded responses.
@MainActor
final class MtrProbeEngine {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "mtr-probe")

    /// Atomic identifier counter shared with PingCommand
    private static let identifierLock = UnfairLock()
    private nonisolated(unsafe) static var nextIdentifier: UInt16 = 1

    static func allocateIdentifier() -> UInt16 {
        identifierLock.withLock {
            let id = nextIdentifier
            nextIdentifier &+= 1
            return id
        }
    }

    // MARK: - Types

    enum ProbeResult: Sendable {
        case timeExceeded(hopIP: String, rtt: Double, ttl: Int, seq: UInt16)
        case echoReply(hopIP: String, rtt: Double, ttl: Int, seq: UInt16)
        case timeout(ttl: Int, seq: UInt16)
    }

    struct InFlightProbe: Sendable {
        let ttl: Int
        let sequenceNumber: UInt16
        let sendTime: timeval
    }

    private struct ControlInfo {
        var ttl: Int = 0
        var receiveTime: timeval?
    }

    // MARK: - Properties

    let isIPv6: Bool
    private var socketFD: Int32 = -1
    private let identifier: UInt16
    private var kernelIdentifier: UInt16?
    private let payloadNonce: UInt64
    private var sequenceCounter: UInt16 = 0
    private var inFlightProbes: [UInt16: InFlightProbe] = [:]

    private static let payloadNonceSize = MemoryLayout<UInt64>.size
    private static let payloadTimestampSize = MemoryLayout<timeval>.size

    init(isIPv6: Bool) {
        self.isIPv6 = isIPv6
        self.identifier = Self.allocateIdentifier()
        self.payloadNonce = UInt64.random(in: UInt64.min...UInt64.max)
    }

    // MARK: - Socket Lifecycle

    func openSocket(tos: Int = 0) -> Bool {
        let proto = isIPv6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        socketFD = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, proto)
        guard socketFD >= 0 else { return false }

        // Non-blocking so recvmsg() returns EAGAIN instead of blocking MainActor
        let flags = fcntl(socketFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        }

        // Enable ancillary data
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_TIMESTAMP, &on, socklen_t(MemoryLayout<Int32>.size))
        if isIPv6 {
            setsockopt(socketFD, IPPROTO_IPV6, kIPV6_RECVHOPLIMIT, &on, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(socketFD, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        // TOS / Traffic Class
        if tos > 0 {
            var tosVal = Int32(tos)
            if isIPv6 {
                setsockopt(socketFD, IPPROTO_IPV6, IPV6_TCLASS, &tosVal, socklen_t(MemoryLayout<Int32>.size))
            } else {
                setsockopt(socketFD, IPPROTO_IP, IP_TOS, &tosVal, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        return true
    }

    func closeSocket() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    var isOpen: Bool { socketFD >= 0 }

    // MARK: - Sending Probes

    /// Send an ICMP echo request at the given TTL. Returns the sequence number used.
    func sendProbe(ttl: Int, target: UnsafeMutablePointer<addrinfo>, packetSize: Int, bitPattern: Int) -> UInt16 {
        // Set TTL for this probe
        var ttlVal = Int32(ttl)
        if isIPv6 {
            setsockopt(socketFD, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &ttlVal, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(socketFD, IPPROTO_IP, IP_TTL, &ttlVal, socklen_t(MemoryLayout<Int32>.size))
        }

        let seq = sequenceCounter
        sequenceCounter &+= 1

        // Build ICMP packet
        let headerSize = 8
        let totalSize = headerSize + packetSize
        var packet = [UInt8](repeating: 0, count: totalSize)

        // Type: Echo Request
        packet[0] = isIPv6 ? 128 : 8
        packet[1] = 0  // Code
        // Checksum placeholder
        packet[2] = 0
        packet[3] = 0
        // Identifier
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        // Sequence number
        packet[6] = UInt8(seq >> 8)
        packet[7] = UInt8(seq & 0xFF)

        // Embed nonce + timestamp in payload
        let payloadPrefixBytes = embedPayloadPrefix(into: &packet, headerSize: headerSize, packetSize: packetSize)

        // Fill remaining with bit pattern
        let dataStart = headerSize + payloadPrefixBytes
        let fillByte: UInt8
        if bitPattern > 255 {
            fillByte = UInt8.random(in: 0...255)
        } else {
            fillByte = UInt8(bitPattern & 0xFF)
        }
        for j in dataStart..<totalSize {
            packet[j] = fillByte
        }

        // IPv4 needs manual checksum
        if !isIPv6 {
            let cksum = icmpChecksum(packet)
            packet[2] = UInt8(cksum >> 8)
            packet[3] = UInt8(cksum & 0xFF)
        }

        // Record send time
        var sendTime = timeval()
        gettimeofday(&sendTime, nil)

        // Track in-flight
        inFlightProbes[seq] = InFlightProbe(ttl: ttl, sequenceNumber: seq, sendTime: sendTime)

        // Send
        let sent = sendto(
            socketFD,
            packet,
            totalSize,
            0,
            target.pointee.ai_addr,
            target.pointee.ai_addrlen
        )

        if sent < 0 {
            let err = String(cString: strerror(errno))
            Self.logger.error("sendto failed for TTL \(ttl): \(err)")
        }

        // Learn kernel identifier after first send
        if kernelIdentifier == nil {
            learnKernelIdentifier()
        }

        return seq
    }

    // MARK: - Receiving Probes

    /// Collect probe results with a timeout. Returns all results received.
    /// Uses non-blocking recvmsg() + cooperative Task.sleep to avoid blocking MainActor.
    func receiveProbes(timeout: TimeInterval) async -> [ProbeResult] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var results: [ProbeResult] = []

        while !Task.isCancelled {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { break }

            // Non-blocking drain: read all available packets
            while let result = receiveOnePacket() {
                results.append(result)
            }

            // Yield MainActor via cooperative sleep
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }

        return results
    }

    /// Check for timed-out probes and return timeout results.
    func expireProbes(olderThan timeout: TimeInterval) -> [ProbeResult] {
        var now = timeval()
        gettimeofday(&now, nil)
        let nowAbs = Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000.0
        var results: [ProbeResult] = []

        let expired = inFlightProbes.filter { (_, probe) in
            let sendAbs = Double(probe.sendTime.tv_sec) + Double(probe.sendTime.tv_usec) / 1_000_000.0
            return (nowAbs - sendAbs) >= timeout
        }

        for (seq, probe) in expired {
            results.append(.timeout(ttl: probe.ttl, seq: seq))
            inFlightProbes.removeValue(forKey: seq)
        }

        return results
    }

    /// Whether any probes are still awaiting responses
    var hasInFlightProbes: Bool {
        !inFlightProbes.isEmpty
    }

    /// Clear all in-flight probes (for reset)
    func clearInFlight() {
        inFlightProbes.removeAll()
    }

    // MARK: - Private Receive

    private func receiveOnePacket() -> ProbeResult? {
        guard socketFD >= 0 else { return nil }

        var recvBuf = [UInt8](repeating: 0, count: 65536)
        var controlBuf = [UInt8](repeating: 0, count: 256)
        var srcAddr = sockaddr_storage()
        var iov = iovec()
        var msg = msghdr()

        let (bytesRead, controlInfo): (Int, ControlInfo) = recvBuf.withUnsafeMutableBufferPointer { bufPtr in
            controlBuf.withUnsafeMutableBufferPointer { ctlPtr in
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            guard let recvBase = bufPtr.baseAddress,
                                  let controlBase = ctlPtr.baseAddress else {
                                return (-1, ControlInfo())
                            }

                            iovPtr.pointee.iov_base = UnsafeMutableRawPointer(recvBase)
                            iovPtr.pointee.iov_len = bufPtr.count

                            msg.msg_name = UnsafeMutableRawPointer(sockPtr)
                            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                            msg.msg_iov = iovPtr
                            msg.msg_iovlen = 1
                            msg.msg_control = UnsafeMutableRawPointer(controlBase)
                            msg.msg_controllen = socklen_t(ctlPtr.count)

                            let n = recvmsg(socketFD, &msg, 0)
                            let info = n > 0 ? extractControlInfo(msg: &msg, maxLength: ctlPtr.count) : ControlInfo()
                            return (n, info)
                        }
                    }
                }
            }
        }

        guard bytesRead >= 8 else { return nil }

        // Handle IPv4 header prefix
        var icmpOffset = 0
        if !isIPv6 {
            let versionNibble = (recvBuf[0] & 0xF0) >> 4
            if versionNibble == 4 {
                icmpOffset = Int(recvBuf[0] & 0x0F) * 4
            }
        }

        guard bytesRead >= icmpOffset + 8 else { return nil }

        let icmpType = recvBuf[icmpOffset]
        let sourceIP = extractSourceAddress(&srcAddr)

        // Echo Reply: IPv4 type 0, IPv6 type 129
        let echoReplyType: UInt8 = isIPv6 ? 129 : 0
        // Time Exceeded: IPv4 type 11, IPv6 type 3
        let timeExceededType: UInt8 = isIPv6 ? 3 : 11

        if icmpType == echoReplyType {
            return handleEchoReply(recvBuf: recvBuf, icmpOffset: icmpOffset, bytesRead: bytesRead,
                                   sourceIP: sourceIP, controlInfo: controlInfo)
        } else if icmpType == timeExceededType {
            return handleTimeExceeded(recvBuf: recvBuf, icmpOffset: icmpOffset, bytesRead: bytesRead,
                                      sourceIP: sourceIP, controlInfo: controlInfo)
        }

        return nil
    }

    private func handleEchoReply(recvBuf: [UInt8], icmpOffset: Int, bytesRead: Int,
                                  sourceIP: String, controlInfo: ControlInfo) -> ProbeResult? {
        // Filter by kernel identifier
        let recvIdentifier = UInt16(recvBuf[icmpOffset + 4]) << 8 | UInt16(recvBuf[icmpOffset + 5])
        if let expectedID = kernelIdentifier, recvIdentifier != expectedID {
            return nil
        }

        let recvSeq = UInt16(recvBuf[icmpOffset + 6]) << 8 | UInt16(recvBuf[icmpOffset + 7])
        let dataOffset = icmpOffset + 8
        let dataLen = bytesRead - dataOffset

        // Check nonce
        if !payloadNonceMatches(buffer: recvBuf, payloadOffset: dataOffset, payloadLength: dataLen) {
            return nil
        }

        // Look up in-flight probe
        guard let probe = inFlightProbes.removeValue(forKey: recvSeq) else { return nil }

        let rtt = calculateRTT(
            buffer: recvBuf, payloadOffset: dataOffset, payloadLength: dataLen,
            sendTime: probe.sendTime, receiveTime: controlInfo.receiveTime
        )

        return .echoReply(hopIP: sourceIP, rtt: rtt, ttl: probe.ttl, seq: recvSeq)
    }

    private func handleTimeExceeded(recvBuf: [UInt8], icmpOffset: Int, bytesRead: Int,
                                     sourceIP: String, controlInfo: ControlInfo) -> ProbeResult? {
        // Time Exceeded structure:
        // [ICMP TE header: type(1) code(1) checksum(2) unused(4) = 8 bytes]
        // [Embedded original IP header: variable length]
        // [Embedded original ICMP Echo: type(1) code(1) checksum(2) id(2) seq(2) = 8 bytes]
        // [Embedded payload: nonce(8) + timestamp(16)]

        let teHeaderEnd = icmpOffset + 8  // End of Time Exceeded ICMP header

        // Parse embedded IP header to find embedded ICMP.
        // Under NAT64, the outer packet is IPv6 (Time Exceeded) but the embedded
        // original packet may still be IPv4 if the carrier gateway didn't fully
        // translate the inner header.  Check the actual version nibble.
        let embeddedIPOffset = teHeaderEnd
        guard bytesRead > embeddedIPOffset else { return nil }
        let embeddedVersionNibble = (recvBuf[embeddedIPOffset] & 0xF0) >> 4
        let embeddedICMPOffset: Int

        if embeddedVersionNibble == 6 {
            // IPv6: fixed 40-byte header
            embeddedICMPOffset = embeddedIPOffset + 40
        } else if embeddedVersionNibble == 4 {
            // IPv4: IHL field gives length in 32-bit words (also handles NAT64)
            let embeddedIHL = Int(recvBuf[embeddedIPOffset] & 0x0F) * 4
            guard embeddedIHL >= 20 else { return nil }
            embeddedICMPOffset = embeddedIPOffset + embeddedIHL
        } else {
            return nil
        }

        // Need at least 8 bytes for embedded ICMP header
        guard bytesRead >= embeddedICMPOffset + 8 else { return nil }

        // Verify embedded ICMP is Echo Request.
        // Accept both IPv4 (type 8) and IPv6 (type 128) — under NAT64 the
        // embedded packet type may not match the outer IP version.
        let embeddedType = recvBuf[embeddedICMPOffset]
        guard embeddedType == 8 || embeddedType == 128 else { return nil }

        let embeddedSeq = UInt16(recvBuf[embeddedICMPOffset + 6]) << 8 | UInt16(recvBuf[embeddedICMPOffset + 7])

        // Check nonce first — it survives NAT64 intact, whereas the kernel
        // identifier may be rewritten by carrier gateways.
        let embeddedPayloadOffset = embeddedICMPOffset + 8
        let embeddedPayloadLen = bytesRead - embeddedPayloadOffset
        if embeddedPayloadLen >= Self.payloadNonceSize {
            if !payloadNonceMatches(buffer: recvBuf, payloadOffset: embeddedPayloadOffset, payloadLength: embeddedPayloadLen) {
                return nil
            }
        } else {
            // No nonce available — fall back to identifier check
            let embeddedIdentifier = UInt16(recvBuf[embeddedICMPOffset + 4]) << 8 | UInt16(recvBuf[embeddedICMPOffset + 5])
            if let expectedID = kernelIdentifier, embeddedIdentifier != expectedID {
                return nil
            }
        }

        // Look up in-flight probe
        guard let probe = inFlightProbes.removeValue(forKey: embeddedSeq) else { return nil }

        // Calculate RTT from embedded timestamp if available, otherwise from send time
        let rtt: Double
        if embeddedPayloadLen >= Self.payloadNonceSize + Self.payloadTimestampSize {
            rtt = calculateRTT(
                buffer: recvBuf, payloadOffset: embeddedPayloadOffset, payloadLength: embeddedPayloadLen,
                sendTime: probe.sendTime, receiveTime: controlInfo.receiveTime
            )
        } else {
            // Fall back to send time
            rtt = calculateRTTFromSendTime(sendTime: probe.sendTime, receiveTime: controlInfo.receiveTime)
        }

        return .timeExceeded(hopIP: sourceIP, rtt: rtt, ttl: probe.ttl, seq: embeddedSeq)
    }

    // MARK: - DNS Resolution

    nonisolated func resolveHost(_ host: String, family: MtrCommandParser.MtrConfig.AddressFamily) async -> UnsafeMutablePointer<addrinfo>? {
        let aiFamily: Int32
        switch family {
        case .ipv4: aiFamily = AF_INET
        case .ipv6: aiFamily = AF_INET6
        case .unspecified: aiFamily = AF_UNSPEC
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = aiFamily
                hints.ai_socktype = SOCK_DGRAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                if status != 0 {
                    MtrProbeEngine.logger.error("getaddrinfo failed for \(host): \(String(cString: gai_strerror(status)))")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    func extractIPAddress(_ addrInfo: UnsafeMutablePointer<addrinfo>) -> String {
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard let rawAddress = addrInfo.pointee.ai_addr else { return "" }

        if addrInfo.pointee.ai_family == AF_INET6 {
            var addr6 = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in6.self).pointee
            guard inet_ntop(AF_INET6, &addr6.sin6_addr, &ipStr, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "" }
        } else {
            var addr4 = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in.self).pointee
            guard inet_ntop(AF_INET, &addr4.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        }

        return String(cString: ipStr)
    }

    func determineIsIPv6(_ addrInfo: UnsafeMutablePointer<addrinfo>) -> Bool {
        addrInfo.pointee.ai_family == AF_INET6
    }

    // MARK: - Private Helpers

    private func learnKernelIdentifier() {
        if isIPv6 {
            var addr6 = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getsockname(socketFD, sockPtr, &len)
                }
            }
            if result == 0 {
                let id = UInt16(bigEndian: addr6.sin6_port)
                if id != 0 { kernelIdentifier = id }
            }
        } else {
            var addr4 = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr4) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getsockname(socketFD, sockPtr, &len)
                }
            }
            if result == 0 {
                let id = UInt16(bigEndian: addr4.sin_port)
                if id != 0 { kernelIdentifier = id }
            }
        }
    }

    private func embedPayloadPrefix(into packet: inout [UInt8], headerSize: Int, packetSize: Int) -> Int {
        guard packetSize > 0 else { return 0 }

        var payloadOffset = 0

        // Session nonce first
        let nonceBytesToWrite = min(Self.payloadNonceSize, packetSize)
        var nonce = payloadNonce.littleEndian
        withUnsafeBytes(of: &nonce) { nonceBytes in
            for index in 0..<nonceBytesToWrite {
                packet[headerSize + index] = nonceBytes[index]
            }
        }
        payloadOffset += nonceBytesToWrite

        // Timestamp follows nonce
        let remaining = packetSize - payloadOffset
        if remaining >= Self.payloadTimestampSize {
            var tv = timeval()
            gettimeofday(&tv, nil)
            withUnsafeBytes(of: &tv) { tvBytes in
                for index in 0..<Self.payloadTimestampSize {
                    packet[headerSize + payloadOffset + index] = tvBytes[index]
                }
            }
            payloadOffset += Self.payloadTimestampSize
        }

        return payloadOffset
    }

    private func icmpChecksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0

        while i < data.count - 1 {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count {
            sum += UInt32(data[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func payloadNonceMatches(buffer: [UInt8], payloadOffset: Int, payloadLength: Int) -> Bool {
        guard payloadLength >= Self.payloadNonceSize else { return payloadLength == 0 }

        var nonce = payloadNonce.littleEndian
        return withUnsafeBytes(of: &nonce) { nonceBytes in
            for index in 0..<Self.payloadNonceSize {
                guard payloadOffset + index < buffer.count else { return false }
                if buffer[payloadOffset + index] != nonceBytes[index] {
                    return false
                }
            }
            return true
        }
    }

    private func calculateRTT(buffer: [UInt8], payloadOffset: Int, payloadLength: Int,
                               sendTime: timeval, receiveTime: timeval?) -> Double {
        let timestampOffset = payloadOffset + Self.payloadNonceSize
        let requiredLength = Self.payloadNonceSize + Self.payloadTimestampSize
        guard payloadLength >= requiredLength else {
            return calculateRTTFromSendTime(sendTime: sendTime, receiveTime: receiveTime)
        }

        var embeddedSendTime = timeval()
        withUnsafeMutableBytes(of: &embeddedSendTime) { sendPtr in
            for index in 0..<Self.payloadTimestampSize {
                guard timestampOffset + index < buffer.count else { return }
                sendPtr[index] = buffer[timestampOffset + index]
            }
        }

        let sendAbs = Double(embeddedSendTime.tv_sec) + Double(embeddedSendTime.tv_usec) / 1_000_000.0
        let recvTimeval: timeval = receiveTime ?? {
            var now = timeval()
            gettimeofday(&now, nil)
            return now
        }()
        let recvAbs = Double(recvTimeval.tv_sec) + Double(recvTimeval.tv_usec) / 1_000_000.0
        return max(0, (recvAbs - sendAbs) * 1000.0)
    }

    private func calculateRTTFromSendTime(sendTime: timeval, receiveTime: timeval?) -> Double {
        let recvTimeval: timeval = receiveTime ?? {
            var now = timeval()
            gettimeofday(&now, nil)
            return now
        }()
        let sendAbs = Double(sendTime.tv_sec) + Double(sendTime.tv_usec) / 1_000_000.0
        let recvAbs = Double(recvTimeval.tv_sec) + Double(recvTimeval.tv_usec) / 1_000_000.0
        return max(0, (recvAbs - sendAbs) * 1000.0)
    }

    private func extractControlInfo(msg: inout msghdr, maxLength: Int) -> ControlInfo {
        guard let controlBase = msg.msg_control else { return ControlInfo() }
        let controlLen = min(maxLength, Int(msg.msg_controllen))
        let headerSize = MemoryLayout<cmsghdr>.size
        let alignMask = MemoryLayout<Int>.size - 1
        var offset = 0
        var info = ControlInfo()

        while offset + headerSize <= controlLen {
            let cmsgPtr = controlBase.advanced(by: offset)
            let cmsg = cmsgPtr.assumingMemoryBound(to: cmsghdr.self).pointee
            let cmsgLen = Int(cmsg.cmsg_len)

            guard cmsgLen >= headerSize else { break }
            guard cmsgLen <= controlLen - offset else { break }

            let cmsgDataLen = cmsgLen - headerSize

            if isIPv6 {
                if cmsg.cmsg_level == IPPROTO_IPV6 && (cmsg.cmsg_type == kIPV6_HOPLIMIT || cmsg.cmsg_type == kIPV6_2292HOPLIMIT) {
                    guard cmsgDataLen >= MemoryLayout<Int32>.size else {
                        offset += ((cmsgLen + alignMask) & ~alignMask)
                        continue
                    }
                    let dataPtr = cmsgPtr.advanced(by: headerSize)
                    var ttlValue: Int32 = 0
                    memcpy(&ttlValue, dataPtr, MemoryLayout<Int32>.size)
                    info.ttl = Int(ttlValue)
                }
            } else {
                if cmsg.cmsg_level == IPPROTO_IP && cmsg.cmsg_type == IP_RECVTTL {
                    let dataPtr = cmsgPtr.advanced(by: headerSize)
                    if cmsgDataLen >= MemoryLayout<Int32>.size {
                        var ttlValue: Int32 = 0
                        memcpy(&ttlValue, dataPtr, MemoryLayout<Int32>.size)
                        info.ttl = Int(ttlValue)
                    } else if cmsgDataLen >= MemoryLayout<UInt8>.size {
                        info.ttl = Int(dataPtr.assumingMemoryBound(to: UInt8.self).pointee)
                    }
                }
            }

            if cmsg.cmsg_level == SOL_SOCKET &&
               cmsg.cmsg_type == kSCM_TIMESTAMP &&
               cmsgDataLen >= MemoryLayout<timeval>.size {
                let dataPtr = cmsgPtr.advanced(by: headerSize)
                var recvTime = timeval()
                memcpy(&recvTime, dataPtr, MemoryLayout<timeval>.size)
                if recvTime.tv_sec > 0 || recvTime.tv_usec > 0 {
                    info.receiveTime = recvTime
                }
            }

            guard cmsgLen <= Int.max - alignMask else { break }
            let alignedLen = (cmsgLen + alignMask) & ~alignMask
            guard alignedLen > 0 else { break }
            offset += alignedLen
        }

        return info
    }

    // MARK: - NAT64 Support

    /// NAT64 prefix info detected via RFC 7050 / RFC 6052.
    struct NAT64Prefix: Sendable {
        /// Full 16 bytes of the synthesized address with the well-known IPv4 zeroed out,
        /// used as a mask.  Only the prefix bits are non-zero.
        let prefixBytes: [UInt8]
        /// RFC 6052 prefix length in bits (32, 40, 48, 56, 64, or 96).
        let prefixBits: Int
        /// Byte offset where the IPv4 address is embedded (per RFC 6052 table).
        let ipv4Offset: Int
        /// First byte index after the IPv4 + u-octet region; bytes [suffixStart..<16] must be zero.
        let suffixStart: Int
    }

    /// RFC 7050 well-known IPv4 addresses for ipv4only.arpa.
    private nonisolated static let wka170: [UInt8] = [192, 0, 0, 170] // c0:00:00:aa
    private nonisolated static let wka171: [UInt8] = [192, 0, 0, 171] // c0:00:00:ab

    /// RFC 6052 § 2.2: Valid prefix lengths, IPv4 embedding offsets, and suffix start.
    /// Byte 8 is the reserved "u" octet; IPv4 bytes skip it for prefixes shorter than /96.
    /// suffixStart is the first byte after the IPv4 + u-octet region that must be zero.
    private nonisolated static let rfc6052Layouts: [(prefixBits: Int, ipv4Offset: Int, suffixStart: Int)] = [
        (32, 4, 9),    // /32:  prefix[0-3], IPv4[4-7], u[8], suffix[9-15]
        (40, 5, 10),   // /40:  prefix[0-4], IPv4[5-7,9], u[8], suffix[10-15]
        (48, 6, 11),   // /48:  prefix[0-5], IPv4[6-7,9-10], u[8], suffix[11-15]
        (56, 7, 12),   // /56:  prefix[0-6], IPv4[7,9-11], u[8], suffix[12-15]
        (64, 9, 13),   // /64:  prefix[0-7], u[8], IPv4[9-12], suffix[13-15]
        (96, 12, 16),  // /96:  prefix[0-11], IPv4[12-15], no suffix
    ]

    /// Detect the network's NAT64 prefix using RFC 7050 (DNS64 discovery via ipv4only.arpa).
    /// Runs DNS resolution off the main thread. Supports all RFC 6052 prefix lengths.
    /// Cross-validates both well-known addresses (192.0.0.170 and .171) when available.
    nonisolated static func detectNAT64Prefix() async -> NAT64Prefix? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET6
                hints.ai_socktype = SOCK_DGRAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo("ipv4only.arpa", nil, &hints, &result)
                guard status == 0, let head = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(head) }

                // Walk the full linked list, collecting prefix from each WKA independently.
                var prefix170: NAT64Prefix?
                var prefix171: NAT64Prefix?

                var cursor: UnsafeMutablePointer<addrinfo>? = head
                while let entry = cursor {
                    defer { cursor = entry.pointee.ai_next }

                    guard entry.pointee.ai_family == AF_INET6,
                          let rawAddr = entry.pointee.ai_addr else { continue }

                    let addr6 = UnsafeRawPointer(rawAddr)
                        .assumingMemoryBound(to: sockaddr_in6.self).pointee
                    var sin6 = addr6.sin6_addr
                    let bytes: [UInt8] = withUnsafeBytes(of: &sin6) { Array($0) }
                    guard bytes.count == 16 else { continue }

                    if prefix170 == nil, let p = extractPrefix(from: bytes, wka: wka170) {
                        prefix170 = p
                    }
                    if prefix171 == nil, let p = extractPrefix(from: bytes, wka: wka171) {
                        prefix171 = p
                    }
                }

                // Cross-validate: if both WKAs matched, their prefixes must agree.
                if let p170 = prefix170, let p171 = prefix171 {
                    guard p170.prefixBytes == p171.prefixBytes,
                          p170.prefixBits == p171.prefixBits else {
                        // Inconsistent results — reject (possibly poisoned DNS64)
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: p170)
                } else {
                    // Only one (or neither) WKA present — return what we have
                    continuation.resume(returning: prefix170 ?? prefix171)
                }
            }
        }
    }

    /// Try to find the well-known IPv4 address in `bytes` at each RFC 6052 layout position.
    /// Also validates that the "u" octet and suffix bytes are zero per RFC 6052.
    private nonisolated static func extractPrefix(from bytes: [UInt8], wka: [UInt8]) -> NAT64Prefix? {
        for layout in rfc6052Layouts {
            if matchesWKA(bytes: bytes, wka: wka, layout: layout) {
                // Validate "u" octet (byte 8) is zero for prefixes < /96
                if layout.prefixBits < 96, bytes[8] != 0 { continue }
                // Validate suffix bytes are zero
                if (layout.suffixStart..<16).contains(where: { bytes[$0] != 0 }) { continue }

                // Build prefix mask: copy the address, zero out the IPv4 and reserved byte 8
                var prefix = bytes
                writeIPv4(into: &prefix, ipv4: [0, 0, 0, 0], layout: layout)
                if layout.prefixBits < 96 { prefix[8] = 0 }
                return NAT64Prefix(
                    prefixBytes: prefix,
                    prefixBits: layout.prefixBits,
                    ipv4Offset: layout.ipv4Offset,
                    suffixStart: layout.suffixStart
                )
            }
        }
        return nil
    }

    /// Check whether the well-known IPv4 bytes appear at the expected position per RFC 6052.
    /// Byte 8 is reserved ("u" octet) and skipped for prefix lengths shorter than /96.
    private nonisolated static func matchesWKA(bytes: [UInt8], wka: [UInt8],
                                                layout: (prefixBits: Int, ipv4Offset: Int, suffixStart: Int)) -> Bool {
        var wi = 0
        for byteIdx in layout.ipv4Offset..<16 {
            if byteIdx == 8 && layout.prefixBits < 96 { continue } // skip "u" octet
            guard wi < 4 else { break }
            guard bytes[byteIdx] == wka[wi] else { return false }
            wi += 1
        }
        return wi == 4
    }

    /// Write 4 IPv4 bytes into an IPv6 address at the RFC 6052 layout position.
    private nonisolated static func writeIPv4(into bytes: inout [UInt8], ipv4: [UInt8],
                                               layout: (prefixBits: Int, ipv4Offset: Int, suffixStart: Int)) {
        var wi = 0
        for byteIdx in layout.ipv4Offset..<16 {
            if byteIdx == 8 && layout.prefixBits < 96 { continue }
            guard wi < 4 else { break }
            bytes[byteIdx] = ipv4[wi]
            wi += 1
        }
    }

    /// Extract the embedded IPv4 address from a NAT64-synthesized IPv6 address.
    /// Validates prefix match, "u" octet, and suffix per RFC 6052 before translating.
    nonisolated static func nat64ToIPv4(ipv6: String, prefix: NAT64Prefix) -> String? {
        var addr6 = in6_addr()
        guard inet_pton(AF_INET6, ipv6, &addr6) == 1 else { return nil }

        let bytes: [UInt8] = withUnsafeBytes(of: &addr6) { Array($0) }
        guard bytes.count == 16 else { return nil }

        // Verify prefix bytes match
        let prefixByteCount = prefix.prefixBits / 8
        for i in 0..<prefixByteCount {
            guard bytes[i] == prefix.prefixBytes[i] else { return nil }
        }

        // Verify "u" octet (byte 8) is zero for prefixes < /96
        if prefix.prefixBits < 96, bytes[8] != 0 { return nil }

        // Verify suffix bytes are zero
        for i in prefix.suffixStart..<16 {
            guard bytes[i] == 0 else { return nil }
        }

        // Extract IPv4 bytes respecting the RFC 6052 layout (skip byte 8 "u" octet)
        var ipv4Bytes = [UInt8](repeating: 0, count: 4)
        var wi = 0
        for byteIdx in prefix.ipv4Offset..<16 {
            if byteIdx == 8 && prefix.prefixBits < 96 { continue }
            guard wi < 4 else { break }
            ipv4Bytes[wi] = bytes[byteIdx]
            wi += 1
        }
        guard wi == 4 else { return nil }

        var addr4 = in_addr()
        addr4.s_addr = UInt32(ipv4Bytes[0]) | UInt32(ipv4Bytes[1]) << 8
            | UInt32(ipv4Bytes[2]) << 16 | UInt32(ipv4Bytes[3]) << 24
        var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr4, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: ipStr)
    }

    private func extractSourceAddress(_ storage: inout sockaddr_storage) -> String {
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = storage.ss_family

        if family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr6Ptr in
                    var addr = addr6Ptr.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &addr, &ipStr, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                        return "?"
                    }
                    return String(cString: ipStr)
                }
            }
        }

        if family == sa_family_t(AF_INET) {
            return withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr4Ptr in
                    var addr = addr4Ptr.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &ipStr, socklen_t(INET_ADDRSTRLEN)) != nil else {
                        return "?"
                    }
                    return String(cString: ipStr)
                }
            }
        }

        return "?"
    }
}

#endif // !targetEnvironment(macCatalyst)
