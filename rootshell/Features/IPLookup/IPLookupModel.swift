//
//  IPLookupModel.swift
//  rootshell
//
//  IP Lookup HUD state: geo info for an address from the clipboard or the
//  field, or for this network's public addresses discovered over STUN.
//

import Foundation
import Observation
import UIKit

@MainActor @Observable
final class IPLookupModel {
    struct Row: Identifiable {
        enum Origin { case clipboard, entered, publicIPv4, publicIPv6 }
        enum Status { case discovering, resolving, resolved, failed(String) }

        let origin: Origin
        var address: String?
        var geo: GeoInfo?
        var status: Status
        var id: Origin { origin }
    }

    /// Matches the whatismyip command: 3s per STUN server.
    private static let stunTimeout: TimeInterval = 3.0

    var query = ""
    private(set) var rows: [Row] = []
    private(set) var inputError: String?
    private(set) var copiedOrigin: Row.Origin?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var copiedResetTask: Task<Void, Never>?

    init(clipboardText: String?) {
        if let address = clipboardText.flatMap(IPAddressExtractor.firstAddress(in:)) {
            lookUp(address, origin: .clipboard)
        } else {
            discoverPublicAddresses()
        }
    }

    /// Return in the field: look up the typed address, or this network's when empty.
    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            discoverPublicAddresses()
            return
        }
        guard let address = IPAddressExtractor.firstAddress(in: text) else {
            inputError = String(localized: "Not an IPv4 or IPv6 address", comment: "IP Lookup field error")
            return
        }
        lookUp(address, origin: .entered)
    }

    func clearInputError() {
        inputError = nil
    }

    func discoverPublicAddresses() {
        start()
        // IPv4 is always attempted: NAT64 networks report no IPv4 yet reach
        // IPv4 STUN servers through DNS64.
        rows = [Row(origin: .publicIPv4, status: .discovering)]
        var families: [AddressFamily] = [.ipv4]
        if NetworkReachabilityMonitor.shared.supportsIPv6 {
            rows.append(Row(origin: .publicIPv6, status: .discovering))
            families.append(.ipv6)
        } else {
            rows.append(Row(origin: .publicIPv6, status: .failed(
                String(localized: "Not available on this network", comment: "IP Lookup: no IPv6 connectivity"))))
        }
        tasks = families.map { family in
            Task { [weak self] in await self?.discover(family) }
        }
    }

    func copy(_ row: Row) {
        guard let address = row.address else { return }
        UIPasteboard.general.string = address
        copiedOrigin = row.origin
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copiedOrigin = nil
        }
    }

    func end() {
        tasks.forEach { $0.cancel() }
        tasks = []
        copiedResetTask?.cancel()
    }

    private func start() {
        end()
        inputError = nil
        copiedOrigin = nil
    }

    private func lookUp(_ address: String, origin: Row.Origin) {
        start()
        rows = [Row(origin: origin, address: address, status: .resolving)]
        tasks = [Task { [weak self] in await self?.resolve(address, for: origin) }]
    }

    private func discover(_ family: AddressFamily) async {
        let origin: Row.Origin = family == .ipv6 ? .publicIPv6 : .publicIPv4
        let client = STUNClient()
        do {
            let result = try await client.discover(addressFamily: family, timeout: Self.stunTimeout)
            guard !Task.isCancelled else { return }
            update(origin) {
                $0.address = result.publicIP
                $0.status = .resolving
            }
            await resolve(result.publicIP, for: origin)
        } catch {
            guard !Task.isCancelled else { return }
            update(origin) { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func resolve(_ address: String, for origin: Row.Origin) async {
        let geo = await GeoResolver.shared.resolve(ip: address)
        guard !Task.isCancelled else { return }
        update(origin) {
            $0.geo = geo
            $0.status = .resolved
        }
    }

    private func update(_ origin: Row.Origin, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.origin == origin }) else { return }
        change(&rows[index])
    }
}
