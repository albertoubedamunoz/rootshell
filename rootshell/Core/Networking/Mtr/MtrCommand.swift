#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Main orchestrator for the mtr (rootshell traceroute) command.
/// Ties together probe engine, statistics, display, DNS resolution, and reporting.
@MainActor
final class MtrCommand {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "mtr")

    let config: MtrCommandParser.MtrConfig
    let output: (String) -> Void
    var onComplete: (() -> Void)?

    /// Set to true when the command fails at runtime (DNS resolution, socket error).
    /// Callers can check this after onComplete fires to determine exit status.
    private(set) var didFail: Bool = false

    private var task: Task<Void, Never>?
    private var probeEngine: MtrProbeEngine?
    private var trace: MtrTrace
    private var display: MtrDisplay?
    private var reporter: MtrReporter?
    private var resolver: MtrDNSResolver
    private var addrInfoPtr: UnsafeMutablePointer<addrinfo>?

    private var targetIP: String = ""
    private var targetHost: String = ""
    private var isInteractive: Bool { config.reportMode == nil }

    /// NAT64 prefix detected via RFC 7050, nil when not on a NAT64 network
    private var nat64Prefix: MtrProbeEngine.NAT64Prefix?

    // TUI input state
    private enum InputState {
        case normal
        case promptingInterval(buffer: String)
        case promptingFirstTTL(buffer: String)
        case promptingMaxTTL(buffer: String)
        case promptingPacketSize(buffer: String)
        case promptingFieldOrder(buffer: String)
    }
    private var inputState: InputState = .normal
    private var mutableConfig: MtrCommandParser.MtrConfig

    private var cols: UInt16
    private var rows: UInt16
    private var hasCompleted: Bool = false
    private static let maxRecordedRTTMilliseconds: Double = 3_600_000 // 1 hour cap for corrupted timestamps

    init(config: MtrCommandParser.MtrConfig, cols: UInt16, rows: UInt16,
         output: @escaping (String) -> Void) {
        self.config = config
        self.mutableConfig = config
        self.cols = cols
        self.rows = rows
        self.output = output
        self.trace = MtrTrace(maxTTL: config.maxTTL)
        self.resolver = MtrDNSResolver()
    }

    // MARK: - Lifecycle

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil

        if isInteractive {
            display?.exitAlternateScreen()
        }

        cleanup()
        finish()
    }

    func sendInput(_ data: Data) {
        // Always handle Ctrl-C, even in non-interactive (report) mode
        if data.contains(0x03) {
            cancel()
            return
        }
        guard isInteractive else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        for char in text {
            handleKeypress(char)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        display?.resize(cols: cols, rows: rows)
        if isInteractive {
            redraw()
        }
    }

    // MARK: - Main Run Loop

    private func run() async {
        // Resolve hostname
        let engine = MtrProbeEngine(isIPv6: config.addressFamily == .ipv6)
        guard let addrInfo = await engine.resolveHost(config.target, family: config.addressFamily) else {
            output("mtr: cannot resolve \(config.target): Unknown host\r\n")
            didFail = true
            finish()
            return
        }

        guard !Task.isCancelled else {
            freeaddrinfo(addrInfo)
            return
        }

        self.addrInfoPtr = addrInfo
        targetIP = engine.extractIPAddress(addrInfo)
        targetHost = config.target

        // Determine actual IP version from resolution
        let actualIsIPv6 = engine.determineIsIPv6(addrInfo)
        let actualEngine: MtrProbeEngine
        if actualIsIPv6 != (config.addressFamily == .ipv6) {
            // Resolution returned different address family than requested
            actualEngine = MtrProbeEngine(isIPv6: actualIsIPv6)
        } else {
            actualEngine = engine
        }
        self.probeEngine = actualEngine

        // Detect NAT64: if the target resolved to IPv6, check for a NAT64 prefix
        // so we can translate synthesized IPv6 hop addresses back to IPv4 for display.
        if actualIsIPv6 {
            nat64Prefix = await MtrProbeEngine.detectNAT64Prefix()

            guard !Task.isCancelled else {
                cleanup()
                return
            }

            if let prefix = nat64Prefix {
                let prefixBits = prefix.prefixBits
                Self.logger.info("NAT64 /\(prefixBits) prefix detected")
                // Translate the target IP itself if it's a NAT64 address
                if let ipv4 = MtrProbeEngine.nat64ToIPv4(ipv6: targetIP, prefix: prefix) {
                    targetIP = ipv4
                }
            }
        }

        // Open socket
        guard actualEngine.openSocket(tos: config.tos) else {
            let err = String(cString: strerror(errno))
            output("mtr: socket: \(err)\r\n")
            didFail = true
            cleanup()
            finish()
            return
        }

        // Setup DNS resolver callbacks
        resolver.onHostnameResolved = { [weak self] ip, hostname in
            guard let self else { return }
            // Update trace data
            for i in self.trace.hops.indices {
                if self.trace.hops[i].addresses.contains(ip) {
                    self.trace.hops[i].hostnames[ip] = hostname
                }
            }
            // Emit raw DNS line in raw mode
            if case .raw = self.mutableConfig.reportMode {
                for i in self.trace.hops.indices where self.trace.hops[i].addresses.contains(ip) {
                    self.reporter?.emitRawDNS(ttl: i, hostname: hostname)
                }
            }
        }

        resolver.onASInfoResolved = { [weak self] ip, info in
            guard let self else { return }
            for i in self.trace.hops.indices {
                if self.trace.hops[i].addresses.contains(ip) {
                    self.trace.hops[i].asInfo[ip] = info
                }
            }
        }

        // Setup display/reporter
        if isInteractive {
            let disp = MtrDisplay(cols: cols, rows: rows, output: output)
            self.display = disp
            disp.enterAlternateScreen()
        } else {
            self.reporter = MtrReporter(output: output)
        }

        // Run probe loop
        let cycles = config.reportCycles
        var cycleCount = 0

        // Initial draw so the header/layout appears immediately
        if isInteractive {
            redraw()
        }

        while !Task.isCancelled {
            if let cycles, cycleCount >= cycles {
                break
            }

            guard !(display?.isPaused ?? false) else {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms when paused
                guard !hasCompleted else { break }
                continue
            }

            let isLastRound = cycles.map { cycleCount + 1 >= $0 } ?? false
            let useGrace = isLastRound && !isInteractive && mutableConfig.graceTime > 0
            await runOneRound(skipExpire: useGrace)
            guard !hasCompleted else { break }
            cycleCount += 1

        }

        // Final drain: collect remaining in-flight responses and expire unmatched.
        // Always runs after the last cycle — even with -G 0 — so that replies
        // from the final round's probes aren't silently dropped.  We wait at
        // least probeTimeout (so every probe has a chance to be answered) plus
        // any extra grace the user requested.
        if !Task.isCancelled, !hasCompleted, !isInteractive, let engine = probeEngine {
            let drainTime = mutableConfig.probeTimeout + mutableConfig.graceTime
            let drainEnd = CFAbsoluteTimeGetCurrent() + drainTime
            while !Task.isCancelled && !hasCompleted && engine.hasInFlightProbes {
                let remaining = drainEnd - CFAbsoluteTimeGetCurrent()
                guard remaining > 0 else { break }
                let lateResults = await engine.receiveProbes(timeout: min(0.5, remaining))
                guard !hasCompleted else { break }
                for result in lateResults {
                    processResult(result)
                }
            }
            // Expire anything still unmatched
            let timeouts = engine.expireProbes(olderThan: 0)
            for result in timeouts {
                processResult(result)
            }
        }

        // Finalize (skip if cancel() already handled cleanup)
        if !Task.isCancelled, !hasCompleted {
            if let reportMode = config.reportMode {
                printFinalReport(reportMode)
            } else if isInteractive {
                display?.exitAlternateScreen()
            }
            cleanup()
            finish()
        }
    }

    // MARK: - Probe Round

    private func runOneRound(skipExpire: Bool = false) async {
        guard let engine = probeEngine else { return }

        let firstTTL = mutableConfig.firstTTL
        let maxTTL = mutableConfig.maxTTL

        // Ensure trace has enough hops
        while trace.hops.count < maxTTL {
            trace.hops.append(HopStatistics(maxSamples: MtrTrace.maxSamples))
        }

        // Only probe up to destination TTL once known (real mtr behavior).
        // Before destination is found, probe all TTLs up to maxTTL.
        let effectiveMaxTTL = trace.destinationTTL ?? maxTTL

        // Guard against invalid range (e.g. user set firstTTL > maxTTL interactively).
        // Sleep for the interval to avoid busy-spinning the MainActor when the outer
        // loop has no inter-round delay.
        guard firstTTL <= effectiveMaxTTL else {
            let ns = min(mutableConfig.interval, 60) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(ns))
            return
        }

        // Early exit if cancelled (e.g. cancel() already exited alternate screen)
        guard !hasCompleted else { return }

        // Spread probes across the interval (matching reference mtr's calc_deltatime).
        // This makes each round take ~interval time, collecting responses between sends.
        let numHops = effectiveMaxTTL - firstTTL + 1
        let probeDelay = mutableConfig.interval / Double(numHops)

        // Send one probe per TTL, collecting responses between probes
        // so we can detect the destination mid-round and stop sending.
        for ttl in firstTTL...effectiveMaxTTL {
            guard !Task.isCancelled else { return }

            // If we learned the destination during this round, stop sending
            if let destTTL = trace.destinationTTL, ttl > destTTL {
                break
            }

            let hopIndex = ttl - 1

            guard let addrInfo = addrInfoPtr else { return }
            _ = engine.sendProbe(
                ttl: ttl,
                target: addrInfo,
                packetSize: mutableConfig.packetSize,
                bitPattern: mutableConfig.bitPattern
            )
            trace.hops[hopIndex].recordSent()

            // Start DNS/AS resolution for known addresses
            if !mutableConfig.numeric {
                for addr in trace.hops[hopIndex].addresses {
                    _ = resolver.hostname(for: addr)
                }
            }
            if mutableConfig.showASN {
                for addr in trace.hops[hopIndex].addresses {
                    _ = resolver.asInfo(for: addr)
                }
            }

            // Wait probeDelay between sends, draining responses so we
            // learn destinationTTL as early as possible.
            let earlyResults = await engine.receiveProbes(timeout: probeDelay)
            // After await, cancel() may have already exited alt screen and shown prompt.
            // Bail out to avoid redraw() clearing the main screen.
            guard !hasCompleted else { return }
            if !earlyResults.isEmpty {
                for result in earlyResults {
                    processResult(result)
                }
                if isInteractive { redraw() }
            }
        }

        // Expire timed-out probes (skip on last round when grace period will handle it)
        if !skipExpire {
            let timeouts = engine.expireProbes(olderThan: mutableConfig.probeTimeout)
            for result in timeouts {
                processResult(result)
            }
        }
    }

    /// Translate a hop IP through NAT64 if a prefix is active, otherwise return as-is.
    private func translateNAT64(_ ip: String) -> String {
        guard let prefix = nat64Prefix else { return ip }
        return MtrProbeEngine.nat64ToIPv4(ipv6: ip, prefix: prefix) ?? ip
    }

    private func sanitizedRTT(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return min(value, Self.maxRecordedRTTMilliseconds)
    }

    private func rawRTTMicroseconds(from milliseconds: Double) -> Int {
        let micros = sanitizedRTT(milliseconds) * 1000
        guard micros.isFinite, micros > 0 else { return 0 }
        return Int(min(micros, Double(Int.max)))
    }

    private func processResult(_ result: MtrProbeEngine.ProbeResult) {
        switch result {
        case .timeExceeded(let rawHopIP, let rtt, let ttl, _):
            let hopIP = translateNAT64(rawHopIP)
            let safeRTT = sanitizedRTT(rtt)
            let hopIndex = ttl - 1
            guard hopIndex >= 0, hopIndex < trace.hops.count else { return }
            trace.hops[hopIndex].recordProbe(rtt: safeRTT, fromAddress: hopIP)

            // Start DNS resolution
            if !mutableConfig.numeric {
                _ = resolver.hostname(for: hopIP)
            }
            if mutableConfig.showASN {
                _ = resolver.asInfo(for: hopIP)
            }

            // Raw mode output
            if case .raw = mutableConfig.reportMode {
                if !trace.hops[hopIndex].addresses.contains(hopIP) || trace.hops[hopIndex].addresses.first == hopIP && trace.hops[hopIndex].received == 1 {
                    reporter?.emitRawHop(ttl: hopIndex, ip: hopIP)
                }
                reporter?.emitRawPing(ttl: hopIndex, rttMicroseconds: rawRTTMicroseconds(from: safeRTT))
            }

        case .echoReply(let rawHopIP, let rtt, let ttl, _):
            let hopIP = translateNAT64(rawHopIP)
            let safeRTT = sanitizedRTT(rtt)
            let hopIndex = ttl - 1
            guard hopIndex >= 0, hopIndex < trace.hops.count else { return }
            trace.hops[hopIndex].recordProbe(rtt: safeRTT, fromAddress: hopIP)
            trace.destinationReached = true
            // Destination TTL is the MINIMUM TTL that reaches the target.
            // Probes with TTL >= actual_distance all get echo replies,
            // so we take the smallest to find the real hop count.
            if let existing = trace.destinationTTL {
                trace.destinationTTL = min(existing, ttl)
            } else {
                trace.destinationTTL = ttl
            }

            if !mutableConfig.numeric {
                _ = resolver.hostname(for: hopIP)
            }
            if mutableConfig.showASN {
                _ = resolver.asInfo(for: hopIP)
            }

            if case .raw = mutableConfig.reportMode {
                if trace.hops[hopIndex].received == 1 {
                    reporter?.emitRawHop(ttl: hopIndex, ip: hopIP)
                }
                reporter?.emitRawPing(ttl: hopIndex, rttMicroseconds: rawRTTMicroseconds(from: safeRTT))
            }

        case .timeout(let ttl, _):
            let hopIndex = ttl - 1
            guard hopIndex >= 0, hopIndex < trace.hops.count else { return }
            trace.hops[hopIndex].recordTimeout()

            if case .raw = mutableConfig.reportMode {
                reporter?.emitRawTimeout(ttl: hopIndex)
            }
        }
    }

    // MARK: - Report Output

    private func printFinalReport(_ mode: MtrCommandParser.MtrConfig.ReportMode) {
        switch mode {
        case .report:
            reporter?.printReport(trace: trace, config: mutableConfig, resolver: resolver, targetHost: targetHost)
        case .reportWide:
            reporter?.printWideReport(trace: trace, config: mutableConfig, resolver: resolver, targetHost: targetHost)
        case .csv:
            reporter?.printCSV(trace: trace, config: mutableConfig, resolver: resolver, targetHost: targetHost)
        case .json:
            reporter?.printJSON(trace: trace, config: mutableConfig, resolver: resolver,
                               targetHost: targetHost, targetIP: targetIP)
        case .xml:
            reporter?.printXML(trace: trace, config: mutableConfig, resolver: resolver, targetHost: targetHost)
        case .raw:
            break  // Raw mode emits during probing
        }
    }

    // MARK: - Display

    private func redraw() {
        display?.draw(trace: trace, config: mutableConfig, resolver: resolver,
                     targetHost: targetHost, targetIP: targetIP)
    }

    // MARK: - Keyboard Input (TUI mode)

    private func handleKeypress(_ char: Character) {
        // Handle prompt input states first
        switch inputState {
        case .promptingInterval(var buffer):
            if char == "\r" || char == "\n" {
                if let val = Double(buffer), val > 0 {
                    mutableConfig.interval = val
                }
                inputState = .normal
                redraw()
            } else if char == "\u{1b}" {  // Escape
                inputState = .normal
                redraw()
            } else if char == "\u{7f}" || char == "\u{08}" {  // Backspace
                if !buffer.isEmpty { buffer.removeLast() }
                inputState = .promptingInterval(buffer: buffer)
                output("\(CSI)2K\rInterval (s): \(buffer)")
            } else {
                buffer.append(char)
                inputState = .promptingInterval(buffer: buffer)
                output("\(CSI)2K\rInterval (s): \(buffer)")
            }
            return

        case .promptingFirstTTL(var buffer):
            if char == "\r" || char == "\n" {
                if let val = Int(buffer), val >= 1, val <= mutableConfig.maxTTL {
                    mutableConfig.firstTTL = val
                }
                inputState = .normal
                redraw()
            } else if char == "\u{1b}" {
                inputState = .normal
                redraw()
            } else if char == "\u{7f}" || char == "\u{08}" {
                if !buffer.isEmpty { buffer.removeLast() }
                inputState = .promptingFirstTTL(buffer: buffer)
                output("\(CSI)2K\rFirst TTL: \(buffer)")
            } else {
                buffer.append(char)
                inputState = .promptingFirstTTL(buffer: buffer)
                output("\(CSI)2K\rFirst TTL: \(buffer)")
            }
            return

        case .promptingMaxTTL(var buffer):
            if char == "\r" || char == "\n" {
                if let val = Int(buffer), val >= mutableConfig.firstTTL, val <= 255 {
                    mutableConfig.maxTTL = val
                }
                inputState = .normal
                redraw()
            } else if char == "\u{1b}" {
                inputState = .normal
                redraw()
            } else if char == "\u{7f}" || char == "\u{08}" {
                if !buffer.isEmpty { buffer.removeLast() }
                inputState = .promptingMaxTTL(buffer: buffer)
                output("\(CSI)2K\rMax TTL: \(buffer)")
            } else {
                buffer.append(char)
                inputState = .promptingMaxTTL(buffer: buffer)
                output("\(CSI)2K\rMax TTL: \(buffer)")
            }
            return

        case .promptingPacketSize(var buffer):
            if char == "\r" || char == "\n" {
                if let val = Int(buffer), val >= 0, val <= 65500 {
                    mutableConfig.packetSize = val
                }
                inputState = .normal
                redraw()
            } else if char == "\u{1b}" {
                inputState = .normal
                redraw()
            } else if char == "\u{7f}" || char == "\u{08}" {
                if !buffer.isEmpty { buffer.removeLast() }
                inputState = .promptingPacketSize(buffer: buffer)
                output("\(CSI)2K\rPacket size: \(buffer)")
            } else {
                buffer.append(char)
                inputState = .promptingPacketSize(buffer: buffer)
                output("\(CSI)2K\rPacket size: \(buffer)")
            }
            return

        case .promptingFieldOrder(var buffer):
            if char == "\r" || char == "\n" {
                if !buffer.isEmpty {
                    mutableConfig.fieldOrder = buffer
                }
                inputState = .normal
                redraw()
            } else if char == "\u{1b}" {
                inputState = .normal
                redraw()
            } else if char == "\u{7f}" || char == "\u{08}" {
                if !buffer.isEmpty { buffer.removeLast() }
                inputState = .promptingFieldOrder(buffer: buffer)
                output("\(CSI)2K\rField order (LDRSNBAWVGJMX): \(buffer)")
            } else {
                buffer.append(char)
                inputState = .promptingFieldOrder(buffer: buffer)
                output("\(CSI)2K\rField order (LDRSNBAWVGJMX): \(buffer)")
            }
            return

        case .normal:
            break
        }

        // Normal mode key handling
        let scalar = char.unicodeScalars.first?.value ?? 0

        switch char {
        case "q":
            cancel()
        case "\u{03}":  // Ctrl-C
            cancel()
        case "h", "?":
            display?.isShowingHelp.toggle()
            redraw()
        case "p", " ":
            display?.isPaused.toggle()
            redraw()
        case "d":
            // Cycle display mode
            let current = mutableConfig.displayMode.rawValue
            let next = (current + 1) % 3
            mutableConfig.displayMode = MtrCommandParser.MtrConfig.DisplayMode(rawValue: next) ?? .statistics
            redraw()
        case "n":
            mutableConfig.numeric.toggle()
            redraw()
        case "r":
            trace.reset(keepAddresses: true)
            probeEngine?.clearInFlight()
            display?.resetScroll()
            redraw()
        case "z":
            mutableConfig.showASN.toggle()
            // Trigger AS lookups for known addresses if just enabled
            if mutableConfig.showASN {
                for hop in trace.hops {
                    for addr in hop.addresses {
                        _ = resolver.asInfo(for: addr)
                    }
                }
            }
            redraw()
        case "y":
            mutableConfig.ipInfoMode = (mutableConfig.ipInfoMode + 1) % 7
            redraw()
        case "b":
            mutableConfig.showIPs.toggle()
            redraw()
        case "j":
            // Toggle between standard fields and jitter fields
            if mutableConfig.fieldOrder.contains("J") {
                mutableConfig.fieldOrder = "LS NABWV"
            } else {
                mutableConfig.fieldOrder = "LS NJMX"
            }
            redraw()
        case "+":
            display?.scrollDown(maxHops: trace.displayableHopCount)
            redraw()
        case "-":
            display?.scrollUp()
            redraw()
        case "i":
            inputState = .promptingInterval(buffer: "")
            output("\r\nInterval (s): ")
        case "f":
            inputState = .promptingFirstTTL(buffer: "")
            output("\r\nFirst TTL: ")
        case "m":
            inputState = .promptingMaxTTL(buffer: "")
            output("\r\nMax TTL: ")
        case "s":
            inputState = .promptingPacketSize(buffer: "")
            output("\r\nPacket size: ")
        case "o", "O":
            inputState = .promptingFieldOrder(buffer: "")
            output("\r\nField order (LDRSNBAWVGJMX): ")
        case "t":
            display?.useTruecolor.toggle()
            redraw()
        default:
            if scalar == 0x0C {  // Ctrl-L
                redraw()
            }
        }
    }

    private var CSI: String { "\u{1b}[" }

    // MARK: - Cleanup

    private func cleanup() {
        probeEngine?.closeSocket()
        if let addrInfo = addrInfoPtr {
            freeaddrinfo(addrInfo)
            addrInfoPtr = nil
        }
    }

    private func finish() {
        guard !hasCompleted else { return }
        hasCompleted = true
        onComplete?()
    }
}

#endif // !targetEnvironment(macCatalyst)
