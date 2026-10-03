//
//  CaptureGeoLookup.swift
//  rootshell
//
//  Geo info for captured server addresses, shared by the request list and
//  the overview so each address is looked up once.
//

#if !CHINA_BUILD

import Foundation
import Network
import Observation

@MainActor
@Observable
final class CaptureGeoLookup {
    static let shared = CaptureGeoLookup()

    /// Keyed by `key(for:)`, so a provider switch or cache clear shows fresh data.
    private var results: [String: GeoInfo] = [:]
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var misses: [String: Date] = [:]
    /// The resolver cache generation the stored entries belong to.
    @ObservationIgnored private var generation = 0
    private static let missRetryInterval: TimeInterval = 60

    private init() {}

    /// Key for `ip` under the current provider and cache generation; nil when geo is
    /// disabled or the address is private. Views use it as their `track` task id.
    func key(for ip: String?) -> String? {
        guard let ip, Self.isPublic(ip) else { return nil }
        let provider = GeoResolver.shared.providerType
        guard provider != .disabled else { return nil }
        return "\(GeoResolver.shared.cacheGeneration):\(provider.rawValue):\(ip)"
    }

    func geo(for ip: String?) -> GeoInfo? {
        key(for: ip).flatMap { results[$0] }
    }

    /// Resolves `ip` for as long as the calling view's task runs, retrying misses
    /// so a lookup that failed offline or before MMDB loaded recovers.
    func track(_ ip: String?) async {
        guard let ip, let key = key(for: ip) else { return }
        let current = GeoResolver.shared.cacheGeneration
        if generation != current {
            results.removeAll()
            misses.removeAll()
            inFlight.removeAll()
            generation = current
        }
        while results[key] == nil, !Task.isCancelled {
            await resolve(ip, key: key)
            guard results[key] == nil else { return }
            try? await Task.sleep(for: .seconds(Self.missRetryInterval))
        }
    }

    /// One shared lookup per key, unstructured so a row scrolling away doesn't
    /// cancel it; recent misses wait out the retry interval.
    private func resolve(_ ip: String, key: String) async {
        if let task = inFlight[key] { return await task.value }
        if let missed = misses[key], Date().timeIntervalSince(missed) < Self.missRetryInterval { return }
        let started = generation
        let task = Task {
            let geo = await GeoResolver.shared.resolve(ip: ip)
            // A cache clear while this ran makes the answer stale.
            guard generation == started, GeoResolver.shared.cacheGeneration == started else { return }
            inFlight[key] = nil
            if let geo {
                results[key] = geo
                misses[key] = nil
            } else {
                misses[key] = Date()
            }
        }
        inFlight[key] = task
        await task.value
    }

    /// Private, loopback, link-local, CGNAT, and multicast addresses have no geo data.
    private static func isPublic(_ ip: String) -> Bool {
        if let v4 = IPv4Address(ip) { return isPublic(v4) }
        if let v6 = IPv6Address(ip) {
            if let mapped = v6.asIPv4 { return isPublic(mapped) }
            let b = [UInt8](v6.rawValue)
            return !(v6.isAny || v6.isLoopback || v6.isLinkLocal || v6.isMulticast || (b[0] & 0xFE) == 0xFC)
        }
        return false
    }

    private static func isPublic(_ v4: IPv4Address) -> Bool {
        let b = [UInt8](v4.rawValue)
        switch b[0] {
        case 0, 10, 127: return false
        case 100: return !(64...127).contains(b[1])
        case 169: return b[1] != 254
        case 172: return !(16...31).contains(b[1])
        case 192: return b[1] != 168
        default: return b[0] < 224
        }
    }
}

extension GeoInfo {
    var flag: String? { Self.emojiFlag(for: countryCode) }
}

#endif
