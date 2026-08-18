//
//  LocalShellSession+WhatIsMyIP.swift
//  rootshell
//
//  Discover public IP address via STUN protocol
//

#if !targetEnvironment(macCatalyst)

import Foundation
import Network
import UIKit

extension LocalShellSession {

    // MARK: - Types

    private enum WhatIsMyIPVariant {
        case dual
        case ipv4Only
        case ipv6Only
    }

    // MARK: - Command Handler

    /// Handle whatismyip / whatismyip4 / whatismyip6 commands
    func handleWhatIsMyIPCommand(_ command: String) {
        let tokens = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map(String.init)
        let commandName = tokens[0].lowercased()
        let args = Set(tokens.dropFirst().map { $0.lowercased() })

        let variant: WhatIsMyIPVariant = switch commandName {
        case "whatismyip4": .ipv4Only
        case "whatismyip6": .ipv6Only
        default: .dual
        }

        if args.contains("-h") || args.contains("--help") {
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displayWhatIsMyIPHelp(variant: variant)
            return
        }

        let skipASN = args.contains("-g")

        // Check for a positional IP address argument
        let positionalArgs = tokens.dropFirst().filter { !$0.hasPrefix("-") }
        let lookupIP: String? = positionalArgs.first.flatMap { arg in
            if IPv4Address(arg) != nil || IPv6Address(arg) != nil {
                return arg
            }
            return nil
        }

        // If a non-flag positional arg was given but isn't a valid IP, error out
        if let badArg = positionalArgs.first, lookupIP == nil {
            onOutput?(normalizeLineEndings("whatismyip: invalid IP address '\(badArg)'\n"))
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            displayPrompt()
            return
        }

        // Cancel any previous whatismyip that may still be running
        whatIsMyIPTask?.cancel()
        whatIsMyIPTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded: Bool
            if let ip = lookupIP {
                succeeded = await self.performIPLookup(ip: ip, skipASN: skipASN)
            } else {
                succeeded = await self.performSTUNDiscovery(variant: variant, skipASN: skipASN)
            }
            guard !Task.isCancelled else { return }
            self.lastCommandSucceeded = succeeded
            self.scriptCommandExitCode = succeeded ? 0 : 1
            self.whatIsMyIPTask = nil
            self.displayPrompt()
        }
    }

    // MARK: - IP Lookup (user-provided address)

    private func performIPLookup(ip: String, skipASN: Bool) async -> Bool {
        onOutput?(normalizeLineEndings("\(ip)\n"))

        if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
            guard !Task.isCancelled else { return false }
            await emitGeoLineWithFavicon(geo)
        }

        UIPasteboard.general.string = ip
        onOutput?(normalizeLineEndings("(copied to clipboard)\n"))
        return true
    }

    // MARK: - STUN Discovery

    /// Per-server STUN timeout. With 3 IPv4 servers this means 9s worst case.
    private static let stunTimeout: TimeInterval = 3.0

    private func performSTUNDiscovery(variant: WhatIsMyIPVariant, skipASN: Bool) async -> Bool {
        switch variant {
        case .ipv4Only:
            return await discoverSingleFamily(family: .ipv4, skipASN: skipASN)

        case .ipv6Only:
            return await discoverSingleFamily(family: .ipv6, skipASN: skipASN)

        case .dual:
            return await discoverDualStack(skipASN: skipASN)
        }
    }

    private func discoverSingleFamily(family: AddressFamily, skipASN: Bool) async -> Bool {
        // Skip IPv6 early if unavailable (no NAT46 equivalent exists).
        // IPv4 is NOT skipped even when supportsIPv4 is false, because NAT64
        // networks (e.g. T-Mobile) can reach IPv4 STUN servers via DNS64.
        if family == .ipv6 && !NetworkReachabilityMonitor.shared.supportsIPv6 {
            onOutput?(normalizeLineEndings("IPv6: not available on current network\n"))
            return false
        }

        let client = STUNClient()
        do {
            let result = try await client.discover(addressFamily: family, timeout: Self.stunTimeout)
            guard !Task.isCancelled else { return false }
            let ip = result.publicIP

            // Emit IP immediately so user sees it before geo lookup
            onOutput?(normalizeLineEndings("\(ip)\n"))

            if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
                guard !Task.isCancelled else { return false }
                await emitGeoLineWithFavicon(geo)
            }

            UIPasteboard.general.string = ip
            onOutput?(normalizeLineEndings("(copied to clipboard)\n"))
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            let label = family == .ipv4 ? "IPv4" : "IPv6"
            onOutput?(normalizeLineEndings("\(label): failed - \(error.localizedDescription)\n"))
            return false
        }
    }

    private func discoverDualStack(skipASN: Bool) async -> Bool {
        // Only skip IPv6 if unavailable. IPv4 is always attempted because NAT64
        // networks (e.g. T-Mobile) report supportsIPv4=false yet can still reach
        // IPv4 STUN servers via DNS64-synthesized addresses.
        let hasIPv6 = NetworkReachabilityMonitor.shared.supportsIPv6

        // Query available families concurrently using separate clients
        var ipv4Result: String?
        var ipv4Error: Error?
        var ipv6Result: String?
        var ipv6Error: Error?

        await withTaskGroup(of: (AddressFamily, String?, Error?).self) { group in
            group.addTask { @MainActor in
                let v4Client = STUNClient()
                do {
                    let result = try await v4Client.discover(addressFamily: .ipv4, timeout: Self.stunTimeout)
                    return (.ipv4, result.publicIP, nil)
                } catch {
                    return (.ipv4, nil, error)
                }
            }
            if hasIPv6 {
                group.addTask { @MainActor in
                    let v6Client = STUNClient()
                    do {
                        let result = try await v6Client.discover(addressFamily: .ipv6, timeout: Self.stunTimeout)
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

        guard !Task.isCancelled else { return false }

        // Emit results incrementally — each line appears as soon as it's ready

        // IPv4 line
        if let ip = ipv4Result {
            onOutput?(normalizeLineEndings("IPv4: \(ip)\n"))
            if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
                guard !Task.isCancelled else { return false }
                await emitGeoLineWithFavicon(geo)
            }
        } else if let error = ipv4Error {
            onOutput?(normalizeLineEndings("IPv4: failed - \(error.localizedDescription)\n"))
        }

        // IPv6 line
        if let ip = ipv6Result {
            onOutput?(normalizeLineEndings("IPv6: \(ip)\n"))
            if !skipASN, let geo = await GeoResolver.shared.resolve(ip: ip) {
                guard !Task.isCancelled else { return false }
                await emitGeoLineWithFavicon(geo)
            }
        } else if let error = ipv6Error {
            onOutput?(normalizeLineEndings("IPv6: failed - \(error.localizedDescription)\n"))
        } else if !hasIPv6 {
            onOutput?(normalizeLineEndings("IPv6: not available\n"))
        }

        // Copy successful IPs to clipboard
        let ips = [ipv4Result, ipv6Result].compactMap { $0 }
        if !ips.isEmpty {
            UIPasteboard.general.string = ips.joined(separator: "\n")
            onOutput?(normalizeLineEndings("(copied to clipboard)\n"))
        }
        return !ips.isEmpty
    }

    // MARK: - Formatting

    /// Emit a geo line with an inline favicon before the text if available.
    private func emitGeoLineWithFavicon(_ geo: GeoInfo) async {
        // Try to fetch favicon for the AS domain
        let pngData: Data? = if let domain = geo.asDomain, !domain.isEmpty {
            await FaviconManager.shared.favicon(for: domain)
        } else {
            nil
        }

        // Emit indent, then inline favicon if available, then geo text — all on one line
        let geoText = Self.formatGeoLineContent(geo)
        onOutput?("  ")
        if let pngData {
            let sink = self.onOutput
            let outputSink: @Sendable (String) -> Void = { text in
                sink?(text)
            }
            Self.emitKittyGraphics(pngData: pngData, cols: 2, rows: 1, output: outputSink)
            onOutput?(" ")
        }
        onOutput?(normalizeLineEndings("\(geoText)\n"))
    }

    /// Format geo content without leading indent or trailing newline.
    static func formatGeoLineContent(_ geo: GeoInfo) -> String {
        var parts: [String] = [geo.asNumber]
        if let name = geo.asName, !name.isEmpty {
            parts.append(name)
        }
        if let domain = geo.asDomain, !domain.isEmpty {
            parts.append(domain)
        }
        if !geo.network.isEmpty {
            parts.append(geo.network)
        }
        if let city = geo.cityName, !city.isEmpty {
            parts.append(city)
        }
        if !geo.countryCode.isEmpty {
            parts.append(geo.countryWithFlag)
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Help

    private func displayWhatIsMyIPHelp(variant: WhatIsMyIPVariant) {
        let helpText: String
        switch variant {
        case .dual:
            helpText = """
usage: whatismyip [-g] [<ip>]

Discover your public IPv4 and IPv6 addresses using STUN (RFC 5389).
Displays ASN, network, city, and country info for each address when available.
Both addresses are copied to the clipboard.
IPv6 is skipped automatically if unavailable on the current network.

If <ip> is given, skips STUN discovery and looks up info for that address instead.

Options:
  -g          Skip ASN/geo lookup (IP address only)

"""
        case .ipv4Only:
            helpText = """
usage: whatismyip4 [-g] [<ip>]

Discover your public IPv4 address using STUN (RFC 5389).
Displays ASN, network, city, and country info when available.
The address is copied to the clipboard.

If <ip> is given, skips STUN discovery and looks up info for that address instead.

Options:
  -g          Skip ASN/geo lookup (IP address only)

"""
        case .ipv6Only:
            helpText = """
usage: whatismyip6 [-g] [<ip>]

Discover your public IPv6 address using STUN (RFC 5389).
Displays ASN, network, city, and country info when available.
The address is copied to the clipboard.
Reports immediately if IPv6 is not available on the current network.

If <ip> is given, skips STUN discovery and looks up info for that address instead.

Options:
  -g          Skip ASN/geo lookup (IP address only)

"""
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
