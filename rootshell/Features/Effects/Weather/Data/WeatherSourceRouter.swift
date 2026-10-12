// WeatherSourceRouter.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import os

/// Per-source bookkeeping that survives relaunch: NWS grid lookups (and
/// points NWS does not cover), plus MET Norway's conditional-request headers.
nonisolated struct WeatherSourceState: Codable, Equatable, Sendable {
    var nwsPoints: [String: NWSPointInfo] = [:]
    var nwsUncovered: [String: Date] = [:]
    var metCoordinate: WeatherCoordinate?
    var metValidator: WeatherHTTPValidator?

    mutating func prune(now: Date) {
        nwsPoints = nwsPoints.filter { now.timeIntervalSince($0.value.resolvedAt) < NWSPointInfo.lifetime }
        nwsUncovered = nwsUncovered.filter { now.timeIntervalSince($0.value) < NWSPointInfo.lifetime }
    }
}

nonisolated enum WeatherFetchOutcome: Sendable {
    case updated(WeatherSnapshot)
    case notModified(expiresAt: Date?)
}

/// weather.gov for US locations; Open-Meteo everywhere else and whenever NWS
/// fails; MET Norway if Open-Meteo fails too. All within one refresh.
nonisolated enum WeatherSourceRouter {
    static func fetch(_ coordinate: WeatherCoordinate, previous: WeatherSnapshot?,
                      state: inout WeatherSourceState, now: Date) async throws -> WeatherFetchOutcome {
        state.prune(now: now)
        let key = coordinate.key
        if NWSCoverage.contains(coordinate), state.nwsUncovered[key] == nil {
            do {
                let client = NWSClient()
                let point: NWSPointInfo
                if let cached = state.nwsPoints[key] {
                    point = cached
                } else {
                    point = try await client.point(for: coordinate, now: now)
                    state.nwsPoints[key] = point
                }
                return .updated(try await client.fetch(coordinate, point: point, now: now))
            } catch {
                if case WeatherFetchError.notCovered = error {
                    // A stale grid can also 404; drop it and remember the miss.
                    state.nwsPoints[key] = nil
                    state.nwsUncovered[key] = now
                }
                try Task.checkCancellation()
                Ghostty.logger.info("Live Weather: NWS unavailable (\(String(describing: error), privacy: .public)), using Open-Meteo")
            }
        }
        do {
            return .updated(try await OpenMeteoClient().fetch(coordinate, now: now))
        } catch {
            try Task.checkCancellation()
            Ghostty.logger.info("Live Weather: Open-Meteo unavailable (\(String(describing: error), privacy: .public)), using MET Norway")
        }
        let validator = state.metCoordinate == coordinate && previous?.source == .metNorway
            && previous?.coordinate == coordinate ? state.metValidator : nil
        switch try await METNorwayClient().fetch(coordinate, validator: validator, now: now) {
        case .updated(let snapshot, let next):
            state.metCoordinate = coordinate
            state.metValidator = next
            return .updated(snapshot)
        case .notModified(let next):
            state.metValidator = next
            return .notModified(expiresAt: next.expires)
        }
    }
}
#endif
