//
//  SolarLocationService.swift
//  rootshell
//
//  Lightweight location service for solar position calculations.
//  Requests coarse location for sunrise/sunset times.
//

import Foundation
import CoreLocation
import Combine

/// Errors that can occur during location fetching
enum SolarLocationError: Error, LocalizedError {
    case permissionDenied
    case permissionRestricted
    case locationUnavailable
    case timeout

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location access denied. Solar times will use estimates."
        case .permissionRestricted:
            return "Location access restricted. Solar times will use estimates."
        case .locationUnavailable:
            return "Unable to determine location. Using estimates."
        case .timeout:
            return "Location request timed out. Using estimates."
        }
    }
}

/// Cached location data for persistence
struct CachedSolarLocation: Codable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let locality: String?

    /// Location is valid if less than 30 days old
    var isValid: Bool {
        Date().timeIntervalSince(timestamp) < 30 * 24 * 60 * 60
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Lightweight location service for solar calculations
@MainActor
final class SolarLocationService: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var currentLocation: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var locationError: SolarLocationError?
    @Published private(set) var isRequestingLocation: Bool = false
    @Published private(set) var locality: String?

    // MARK: - Private Properties

    private let locationManager: CLLocationManager
    private let geocoder = CLGeocoder()
    private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var timeoutTask: Task<Void, Never>?

    // MARK: - Persistence Keys

    private static let cacheKey = "solarGraph.cachedLocation"

    // MARK: - Initialization

    override init() {
        self.locationManager = CLLocationManager()
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer

        // Load cached location on init
        if let cached = loadCachedLocation(), cached.isValid {
            self.currentLocation = cached.coordinate
            self.locality = cached.locality
        }
    }

    // MARK: - Public API

    /// Request location permission (call before requestLocation if status is .notDetermined)
    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Fetch location (does NOT auto-request permission - call requestPermission() first)
    func requestLocation() async throws -> CLLocationCoordinate2D {
        // Return cached if available and valid
        if let cached = loadCachedLocation(), cached.isValid {
            currentLocation = cached.coordinate
            locality = cached.locality
            return cached.coordinate
        }

        // Check authorization - don't auto-request, let caller handle permission flow
        switch authorizationStatus {
        case .notDetermined:
            // Permission not requested - throw so caller can handle
            throw SolarLocationError.permissionDenied

        case .authorizedWhenInUse, .authorizedAlways:
            return try await requestLocationUpdate()

        case .denied:
            throw SolarLocationError.permissionDenied

        case .restricted:
            throw SolarLocationError.permissionRestricted

        @unknown default:
            throw SolarLocationError.locationUnavailable
        }
    }

    /// Check if location services are available
    var isLocationAvailable: Bool {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    /// Get best available location (current, cached, or estimated)
    func getBestLocation() -> CLLocationCoordinate2D {
        // Prefer current location
        if let current = currentLocation {
            return current
        }

        // Fall back to cached
        if let cached = loadCachedLocation(), cached.isValid {
            return cached.coordinate
        }

        // Fall back to timezone-based estimate
        return estimatedLocation()
    }

    /// Estimate location from device timezone
    func estimatedLocation() -> CLLocationCoordinate2D {
        let lat = SolarCalculator.estimatedLatitude(from: .current)
        let lon = SolarCalculator.estimatedLongitude(from: .current)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Private Methods

    private func requestLocationUpdate() async throws -> CLLocationCoordinate2D {
        guard !isRequestingLocation else {
            throw SolarLocationError.locationUnavailable
        }

        isRequestingLocation = true
        locationError = nil

        defer {
            isRequestingLocation = false
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation

            // Set timeout
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                if self.locationContinuation != nil {
                    self.locationContinuation?.resume(throwing: SolarLocationError.timeout)
                    self.locationContinuation = nil
                    self.locationError = .timeout
                }
            }

            locationManager.requestLocation()
        }
    }

    // MARK: - Caching

    private func cacheLocation(_ location: CLLocation, locality: String?) {
        let cached = CachedSolarLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: Date(),
            locality: locality
        )

        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }

        self.currentLocation = location.coordinate
        self.locality = locality
    }

    private func loadCachedLocation() -> CachedSolarLocation? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedSolarLocation.self, from: data)
        else {
            return nil
        }
        return cached
    }

    /// Clear cached location
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        currentLocation = nil
        locality = nil
    }

    // MARK: - Geocoding

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self, error == nil,
                  let placemark = placemarks?.first else {
                return
            }

            Task { @MainActor in
                let locality = placemark.locality ?? placemark.administrativeArea
                self.locality = locality

                // Update cache with locality
                self.cacheLocation(location, locality: locality)
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension SolarLocationService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            // Cache the location
            self.cacheLocation(location, locality: nil)

            // Try to get locality name
            self.reverseGeocode(location)

            // Resume continuation if waiting
            self.locationContinuation?.resume(returning: location.coordinate)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let clError = error as? CLError {
                switch clError.code {
                case .denied:
                    self.locationError = .permissionDenied
                    self.locationContinuation?.resume(throwing: SolarLocationError.permissionDenied)
                case .locationUnknown:
                    self.locationError = .locationUnavailable
                    self.locationContinuation?.resume(throwing: SolarLocationError.locationUnavailable)
                default:
                    self.locationError = .locationUnavailable
                    self.locationContinuation?.resume(throwing: SolarLocationError.locationUnavailable)
                }
            } else {
                self.locationError = .locationUnavailable
                self.locationContinuation?.resume(throwing: SolarLocationError.locationUnavailable)
            }
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
        }
    }
}
