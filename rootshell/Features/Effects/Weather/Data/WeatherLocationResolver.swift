// WeatherLocationResolver.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import CoreLocation

enum WeatherLocationStatus: Equatable {
    case city
    case located
    case estimated      // no permission yet, or no fix: a cached fix or a time-zone guess
    case denied
}

struct WeatherResolvedLocation {
    var coordinate: WeatherCoordinate
    var status: WeatherLocationStatus
    /// False for a time-zone guess: good enough for the sun and stars, not for weather.
    var precise: Bool
}

/// Resolves the weather location. Shares Solar's coarse, cached CoreLocation
/// fix, but refreshes it after a few hours so a laptop that travels follows.
@MainActor
final class WeatherLocationResolver {
    static let deviceMaxAge: TimeInterval = 3 * 3600

    private let service = SolarLocationService()

    var locality: String? { service.locality }
    var authorizationStatus: CLAuthorizationStatus { service.authorizationStatus }

    func requestPermissionIfNeeded() {
        if service.authorizationStatus == .notDetermined { service.requestPermission() }
    }

    func resolve(_ selection: WeatherLocationSelection) async -> WeatherResolvedLocation {
        switch selection {
        case .city(let city):
            return WeatherResolvedLocation(coordinate: WeatherCoordinate(latitude: city.latitude, longitude: city.longitude),
                                           status: .city, precise: true)
        case .device:
            switch service.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if let fix = try? await service.requestLocation(maxAge: Self.deviceMaxAge) {
                    return WeatherResolvedLocation(coordinate: WeatherCoordinate(latitude: fix.latitude, longitude: fix.longitude),
                                                   status: .located, precise: true)
                }
                return fallback(.estimated)
            case .denied, .restricted:
                return fallback(.denied)
            default:
                return fallback(.estimated)
            }
        }
    }

    /// A cached fix still counts as precise; a time-zone guess does not.
    private func fallback(_ status: WeatherLocationStatus) -> WeatherResolvedLocation {
        WeatherResolvedLocation(coordinate: bestGuess, status: status, precise: service.currentLocation != nil)
    }

    /// The live fix, then the 30-day cache, then a time-zone estimate.
    var bestGuess: WeatherCoordinate {
        let guess = service.getBestLocation()
        return WeatherCoordinate(latitude: guess.latitude, longitude: guess.longitude)
    }
}
#endif
