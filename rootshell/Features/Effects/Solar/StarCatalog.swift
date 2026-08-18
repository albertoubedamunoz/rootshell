//
//  StarCatalog.swift
//  rootshell
//
//  Star catalog data models and coordinate transformations for rendering
//  real astronomical star positions. Uses Yale Bright Star Catalog data.
//

import Foundation
import CoreLocation
import SwiftUI

// MARK: - Spectral Classification

/// Star spectral classification (Harvard system)
enum SpectralClass: String, Codable, CaseIterable {
    case O, B, A, F, G, K, M

    /// RGB color for this spectral class
    var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .O: return (0.62, 0.68, 1.0)    // Blue
        case .B: return (0.70, 0.78, 1.0)    // Blue-white
        case .A: return (0.85, 0.87, 1.0)    // White
        case .F: return (1.0, 0.96, 0.90)    // Yellow-white
        case .G: return (1.0, 0.93, 0.75)    // Yellow (Sun-like)
        case .K: return (1.0, 0.80, 0.55)    // Orange
        case .M: return (1.0, 0.60, 0.40)    // Red
        }
    }

    /// SwiftUI Color for this spectral class
    var swiftUIColor: Color {
        let rgb = color
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Parse spectral class from string (e.g., "A1V", "G2V", "M3III")
    static func from(spectralString: String) -> SpectralClass {
        guard let first = spectralString.first else { return .G }
        return SpectralClass(rawValue: String(first)) ?? .G
    }
}

// MARK: - Star Data Models

/// A star from the catalog with equatorial coordinates
struct CatalogStar: Codable, Identifiable {
    let id: Int
    let name: String?
    let ra: Double           // Right Ascension in degrees (0-360)
    let dec: Double          // Declination in degrees (-90 to +90)
    let magnitude: Double    // Visual magnitude (brighter = lower)
    let spectral: String     // Spectral classification string

    var spectralClass: SpectralClass {
        SpectralClass.from(spectralString: spectral)
    }

    /// LOD tier based on magnitude
    var lodTier: StarLODTier {
        if magnitude < 1.5 {
            return .primary      // ~20 brightest stars
        } else if magnitude < 3.5 {
            return .secondary    // ~150 medium stars
        } else {
            return .tertiary     // ~300+ dim stars
        }
    }
}

/// Level of detail tier for performance optimization
enum StarLODTier {
    case primary    // Full effects: multi-layer glow, diffraction spikes
    case secondary  // Simplified: single glow + core
    case tertiary   // Minimal: simple dot
}

/// A star ready for rendering with screen coordinates
struct VisibleStar {
    let catalogStar: CatalogStar
    let altitude: Double         // Degrees above horizon
    let azimuth: Double          // Degrees from north
    var screenPosition: CGPoint  // Position in view coordinates

    // Animation properties (deterministic from star ID)
    var twinklePhase: Double {
        Double(catalogStar.id) * 0.73
    }

    var twinkleSpeed: Double {
        1.5 + (Double(catalogStar.id % 100) / 100.0) * 1.0
    }

    /// Atmospheric extinction factor (stars dimmer near horizon)
    var atmosphericExtinction: Double {
        if altitude < 15 {
            return max(0.1, altitude / 15.0)
        }
        return 1.0
    }
}

// MARK: - Star Catalog

/// Manages star catalog data and coordinate transformations
@MainActor
final class StarCatalog {
    static let shared = StarCatalog()

    private var stars: [CatalogStar] = []
    private var isLoaded = false

    private init() {
        loadCatalog()
    }

    // MARK: - Catalog Loading

    private func loadCatalog() {
        guard !isLoaded else { return }

        // Try to load from bundled JSON
        if let url = Bundle.main.url(forResource: "bright_stars", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do {
                let decoder = JSONDecoder()
                let catalog = try decoder.decode(StarCatalogFile.self, from: data)
                stars = catalog.stars
                isLoaded = true
                return
            } catch {
                print("Failed to decode star catalog: \(error)")
            }
        }

        // Fallback to embedded brightest stars
        loadEmbeddedCatalog()
        isLoaded = true
    }

    /// Embedded catalog of the ~100 brightest stars as fallback
    private func loadEmbeddedCatalog() {
        stars = [
            // The 30 brightest stars visible from most locations
            CatalogStar(id: 1, name: "Sirius", ra: 101.287, dec: -16.716, magnitude: -1.46, spectral: "A1V"),
            CatalogStar(id: 2, name: "Canopus", ra: 95.988, dec: -52.696, magnitude: -0.74, spectral: "F0II"),
            CatalogStar(id: 3, name: "Arcturus", ra: 213.915, dec: 19.182, magnitude: -0.05, spectral: "K1.5III"),
            CatalogStar(id: 4, name: "Vega", ra: 279.235, dec: 38.784, magnitude: 0.03, spectral: "A0V"),
            CatalogStar(id: 5, name: "Capella", ra: 79.172, dec: 45.998, magnitude: 0.08, spectral: "G8III"),
            CatalogStar(id: 6, name: "Rigel", ra: 78.634, dec: -8.202, magnitude: 0.13, spectral: "B8Ia"),
            CatalogStar(id: 7, name: "Procyon", ra: 114.827, dec: 5.225, magnitude: 0.34, spectral: "F5IV"),
            CatalogStar(id: 8, name: "Betelgeuse", ra: 88.793, dec: 7.407, magnitude: 0.42, spectral: "M1Ia"),
            CatalogStar(id: 9, name: "Achernar", ra: 24.429, dec: -57.237, magnitude: 0.46, spectral: "B3V"),
            CatalogStar(id: 10, name: "Hadar", ra: 210.956, dec: -60.373, magnitude: 0.61, spectral: "B1III"),
            CatalogStar(id: 11, name: "Altair", ra: 297.696, dec: 8.868, magnitude: 0.76, spectral: "A7V"),
            CatalogStar(id: 12, name: "Acrux", ra: 186.650, dec: -63.099, magnitude: 0.76, spectral: "B0.5IV"),
            CatalogStar(id: 13, name: "Aldebaran", ra: 68.980, dec: 16.509, magnitude: 0.85, spectral: "K5III"),
            CatalogStar(id: 14, name: "Antares", ra: 247.352, dec: -26.432, magnitude: 0.96, spectral: "M1.5Iab"),
            CatalogStar(id: 15, name: "Spica", ra: 201.298, dec: -11.161, magnitude: 0.97, spectral: "B1V"),
            CatalogStar(id: 16, name: "Pollux", ra: 116.329, dec: 28.026, magnitude: 1.14, spectral: "K0III"),
            CatalogStar(id: 17, name: "Fomalhaut", ra: 344.413, dec: -29.622, magnitude: 1.16, spectral: "A3V"),
            CatalogStar(id: 18, name: "Deneb", ra: 310.358, dec: 45.280, magnitude: 1.25, spectral: "A2Ia"),
            CatalogStar(id: 19, name: "Mimosa", ra: 191.930, dec: -59.689, magnitude: 1.25, spectral: "B0.5III"),
            CatalogStar(id: 20, name: "Regulus", ra: 152.093, dec: 11.967, magnitude: 1.35, spectral: "B7V"),

            // Orion constellation
            CatalogStar(id: 21, name: "Bellatrix", ra: 81.283, dec: 6.350, magnitude: 1.64, spectral: "B2III"),
            CatalogStar(id: 22, name: "Alnilam", ra: 84.053, dec: -1.202, magnitude: 1.70, spectral: "B0Ia"),
            CatalogStar(id: 23, name: "Alnitak", ra: 85.190, dec: -1.943, magnitude: 1.77, spectral: "O9.5Ib"),
            CatalogStar(id: 24, name: "Saiph", ra: 86.939, dec: -9.670, magnitude: 2.06, spectral: "B0.5Ia"),
            CatalogStar(id: 25, name: "Mintaka", ra: 83.002, dec: -0.299, magnitude: 2.23, spectral: "O9.5II"),

            // Big Dipper (Ursa Major)
            CatalogStar(id: 26, name: "Dubhe", ra: 165.932, dec: 61.751, magnitude: 1.79, spectral: "K0III"),
            CatalogStar(id: 27, name: "Merak", ra: 165.460, dec: 56.382, magnitude: 2.37, spectral: "A1V"),
            CatalogStar(id: 28, name: "Phecda", ra: 178.458, dec: 53.695, magnitude: 2.44, spectral: "A0V"),
            CatalogStar(id: 29, name: "Megrez", ra: 183.857, dec: 57.033, magnitude: 3.31, spectral: "A3V"),
            CatalogStar(id: 30, name: "Alioth", ra: 193.507, dec: 55.960, magnitude: 1.77, spectral: "A0p"),
            CatalogStar(id: 31, name: "Mizar", ra: 200.981, dec: 54.925, magnitude: 2.27, spectral: "A2V"),
            CatalogStar(id: 32, name: "Alkaid", ra: 206.885, dec: 49.313, magnitude: 1.86, spectral: "B3V"),

            // Scorpius
            CatalogStar(id: 33, name: "Shaula", ra: 263.402, dec: -37.104, magnitude: 1.63, spectral: "B1.5IV"),
            CatalogStar(id: 34, name: "Sargas", ra: 264.330, dec: -42.998, magnitude: 1.87, spectral: "F1II"),
            CatalogStar(id: 35, name: "Dschubba", ra: 240.083, dec: -22.622, magnitude: 2.32, spectral: "B0.3IV"),

            // Cassiopeia
            CatalogStar(id: 36, name: "Schedar", ra: 10.127, dec: 56.537, magnitude: 2.23, spectral: "K0III"),
            CatalogStar(id: 37, name: "Caph", ra: 2.295, dec: 59.150, magnitude: 2.27, spectral: "F2III"),
            CatalogStar(id: 38, name: "Ruchbah", ra: 21.454, dec: 60.235, magnitude: 2.68, spectral: "A5V"),
            CatalogStar(id: 39, name: "Segin", ra: 28.599, dec: 63.670, magnitude: 3.37, spectral: "B3V"),
            CatalogStar(id: 40, name: "Navi", ra: 14.177, dec: 60.717, magnitude: 2.47, spectral: "B0IV"),

            // Leo
            CatalogStar(id: 41, name: "Denebola", ra: 177.265, dec: 14.572, magnitude: 2.14, spectral: "A3V"),
            CatalogStar(id: 42, name: "Algieba", ra: 146.463, dec: 19.842, magnitude: 2.28, spectral: "K0III"),
            CatalogStar(id: 43, name: "Zosma", ra: 168.527, dec: 20.524, magnitude: 2.56, spectral: "A4V"),

            // Cygnus (Northern Cross)
            CatalogStar(id: 44, name: "Sadr", ra: 305.557, dec: 40.257, magnitude: 2.20, spectral: "F8Ib"),
            CatalogStar(id: 45, name: "Gienah", ra: 305.253, dec: 33.970, magnitude: 2.46, spectral: "K0III"),
            CatalogStar(id: 46, name: "Albireo", ra: 292.680, dec: 27.960, magnitude: 3.08, spectral: "K3II"),

            // Lyra
            CatalogStar(id: 47, name: "Sheliak", ra: 282.520, dec: 33.363, magnitude: 3.45, spectral: "A8V"),
            CatalogStar(id: 48, name: "Sulafat", ra: 284.736, dec: 32.690, magnitude: 3.24, spectral: "B9III"),

            // Gemini
            CatalogStar(id: 49, name: "Castor", ra: 113.650, dec: 31.888, magnitude: 1.58, spectral: "A1V"),
            CatalogStar(id: 50, name: "Alhena", ra: 99.428, dec: 16.399, magnitude: 1.93, spectral: "A0IV"),

            // Taurus
            CatalogStar(id: 51, name: "Elnath", ra: 81.573, dec: 28.608, magnitude: 1.65, spectral: "B7III"),
            CatalogStar(id: 52, name: "Alcyone", ra: 56.871, dec: 24.105, magnitude: 2.87, spectral: "B7III"),

            // Canis Major
            CatalogStar(id: 53, name: "Adhara", ra: 104.656, dec: -28.972, magnitude: 1.50, spectral: "B2II"),
            CatalogStar(id: 54, name: "Wezen", ra: 107.098, dec: -26.393, magnitude: 1.84, spectral: "F8Ia"),
            CatalogStar(id: 55, name: "Mirzam", ra: 95.675, dec: -17.956, magnitude: 1.98, spectral: "B1II"),

            // Centaurus
            CatalogStar(id: 56, name: "Alpha Centauri", ra: 219.902, dec: -60.834, magnitude: -0.01, spectral: "G2V"),
            CatalogStar(id: 57, name: "Menkent", ra: 211.671, dec: -36.370, magnitude: 2.06, spectral: "K0III"),

            // Crux (Southern Cross)
            CatalogStar(id: 58, name: "Gacrux", ra: 187.791, dec: -57.113, magnitude: 1.63, spectral: "M3.5III"),
            CatalogStar(id: 59, name: "Imai", ra: 185.340, dec: -58.749, magnitude: 2.80, spectral: "B2IV"),

            // Perseus
            CatalogStar(id: 60, name: "Mirfak", ra: 51.081, dec: 49.861, magnitude: 1.79, spectral: "F5Ib"),
            CatalogStar(id: 61, name: "Algol", ra: 47.042, dec: 40.956, magnitude: 2.12, spectral: "B8V"),

            // Aquila
            CatalogStar(id: 62, name: "Tarazed", ra: 296.565, dec: 10.614, magnitude: 2.72, spectral: "K3II"),
            CatalogStar(id: 63, name: "Alshain", ra: 298.828, dec: 6.407, magnitude: 3.71, spectral: "G8IV"),

            // Sagittarius
            CatalogStar(id: 64, name: "Kaus Australis", ra: 276.043, dec: -34.384, magnitude: 1.85, spectral: "B9.5III"),
            CatalogStar(id: 65, name: "Nunki", ra: 283.816, dec: -26.297, magnitude: 2.02, spectral: "B2.5V"),
            CatalogStar(id: 66, name: "Ascella", ra: 285.653, dec: -29.880, magnitude: 2.59, spectral: "A2IV"),

            // Virgo
            CatalogStar(id: 67, name: "Vindemiatrix", ra: 195.545, dec: 10.959, magnitude: 2.83, spectral: "G8III"),
            CatalogStar(id: 68, name: "Porrima", ra: 190.415, dec: -1.449, magnitude: 2.74, spectral: "F0V"),

            // Bootes
            CatalogStar(id: 69, name: "Izar", ra: 221.247, dec: 27.074, magnitude: 2.37, spectral: "K0II"),
            CatalogStar(id: 70, name: "Muphrid", ra: 208.671, dec: 18.398, magnitude: 2.68, spectral: "G0IV"),

            // Auriga
            CatalogStar(id: 71, name: "Menkalinan", ra: 89.882, dec: 44.948, magnitude: 1.90, spectral: "A2IV"),
            CatalogStar(id: 72, name: "Mahasim", ra: 74.249, dec: 33.166, magnitude: 2.69, spectral: "A0p"),

            // Andromeda
            CatalogStar(id: 73, name: "Alpheratz", ra: 2.097, dec: 29.091, magnitude: 2.06, spectral: "B8IV"),
            CatalogStar(id: 74, name: "Mirach", ra: 17.433, dec: 35.620, magnitude: 2.05, spectral: "M0III"),
            CatalogStar(id: 75, name: "Almach", ra: 30.975, dec: 42.330, magnitude: 2.26, spectral: "K3II"),

            // Pegasus
            CatalogStar(id: 76, name: "Enif", ra: 326.046, dec: 9.875, magnitude: 2.39, spectral: "K2Ib"),
            CatalogStar(id: 77, name: "Scheat", ra: 345.944, dec: 28.083, magnitude: 2.42, spectral: "M2.5II"),
            CatalogStar(id: 78, name: "Markab", ra: 346.190, dec: 15.205, magnitude: 2.49, spectral: "B9III"),
            CatalogStar(id: 79, name: "Algenib", ra: 3.309, dec: 15.184, magnitude: 2.83, spectral: "B2IV"),

            // Aries
            CatalogStar(id: 80, name: "Hamal", ra: 31.793, dec: 23.463, magnitude: 2.00, spectral: "K2III"),
            CatalogStar(id: 81, name: "Sheratan", ra: 28.660, dec: 20.808, magnitude: 2.64, spectral: "A5V"),

            // Pisces
            CatalogStar(id: 82, name: "Eta Piscium", ra: 22.871, dec: 15.346, magnitude: 3.62, spectral: "G7III"),

            // Aquarius
            CatalogStar(id: 83, name: "Sadalsuud", ra: 322.890, dec: -5.571, magnitude: 2.91, spectral: "G0Ib"),
            CatalogStar(id: 84, name: "Sadalmelik", ra: 331.446, dec: -0.320, magnitude: 2.96, spectral: "G2Ib"),

            // Capricornus
            CatalogStar(id: 85, name: "Deneb Algedi", ra: 326.760, dec: -16.127, magnitude: 2.87, spectral: "A7III"),

            // Ophiuchus
            CatalogStar(id: 86, name: "Rasalhague", ra: 263.734, dec: 12.560, magnitude: 2.07, spectral: "A5III"),
            CatalogStar(id: 87, name: "Sabik", ra: 257.595, dec: -15.725, magnitude: 2.43, spectral: "A2V"),

            // Serpens
            CatalogStar(id: 88, name: "Unukalhai", ra: 236.067, dec: 6.426, magnitude: 2.65, spectral: "K2III"),

            // Corona Borealis
            CatalogStar(id: 89, name: "Alphecca", ra: 233.672, dec: 26.715, magnitude: 2.23, spectral: "A0V"),

            // Draco
            CatalogStar(id: 90, name: "Eltanin", ra: 269.152, dec: 51.489, magnitude: 2.23, spectral: "K5III"),
            CatalogStar(id: 91, name: "Rastaban", ra: 262.608, dec: 52.301, magnitude: 2.79, spectral: "G2II"),

            // Polaris (North Star)
            CatalogStar(id: 92, name: "Polaris", ra: 37.954, dec: 89.264, magnitude: 1.98, spectral: "F7Ib"),

            // Additional bright stars
            CatalogStar(id: 93, name: "Peacock", ra: 306.412, dec: -56.735, magnitude: 1.94, spectral: "B2IV"),
            CatalogStar(id: 94, name: "Alnair", ra: 332.058, dec: -46.961, magnitude: 1.74, spectral: "B7IV"),
            CatalogStar(id: 95, name: "Alioth", ra: 193.507, dec: 55.960, magnitude: 1.77, spectral: "A1III"),
            CatalogStar(id: 96, name: "Kochab", ra: 222.676, dec: 74.155, magnitude: 2.08, spectral: "K4III"),
            CatalogStar(id: 97, name: "Diphda", ra: 10.897, dec: -17.987, magnitude: 2.02, spectral: "K0III"),
            CatalogStar(id: 98, name: "Miaplacidus", ra: 138.300, dec: -69.717, magnitude: 1.68, spectral: "A2IV"),
            CatalogStar(id: 99, name: "Ankaa", ra: 6.571, dec: -42.306, magnitude: 2.39, spectral: "K0III"),
            CatalogStar(id: 100, name: "Atria", ra: 252.166, dec: -69.028, magnitude: 1.92, spectral: "K2III"),
        ]
    }

    // MARK: - Coordinate Transformations

    /// Calculate Local Sidereal Time in degrees
    func localSiderealTime(date: Date, longitude: Double) -> Double {
        let jd = julianDay(from: date)
        let T = (jd - 2451545.0) / 36525.0

        // Greenwich Mean Sidereal Time (degrees)
        var gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0) +
                   0.000387933 * T * T - T * T * T / 38710000.0

        // Normalize to 0-360
        gmst = gmst.truncatingRemainder(dividingBy: 360.0)
        if gmst < 0 { gmst += 360.0 }

        // Local Sidereal Time
        var lst = gmst + longitude
        lst = lst.truncatingRemainder(dividingBy: 360.0)
        if lst < 0 { lst += 360.0 }

        return lst
    }

    /// Convert Julian Day from Date
    private func julianDay(from date: Date) -> Double {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)

        var year = components.year ?? 2024
        var month = components.month ?? 1
        let day = components.day ?? 1
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        if month <= 2 {
            year -= 1
            month += 12
        }

        let a = Int(Double(year) / 100.0)
        let b = 2 - a + Int(Double(a) / 4.0)

        let jd = Double(Int(365.25 * Double(year + 4716))) +
                 Double(Int(30.6001 * Double(month + 1))) +
                 Double(day) + Double(b) - 1524.5 +
                 (hour + minute / 60.0 + second / 3600.0) / 24.0

        return jd
    }

    /// Convert equatorial coordinates (RA/Dec) to horizontal (Alt/Az)
    func equatorialToHorizontal(
        ra: Double,
        dec: Double,
        lst: Double,
        latitude: Double
    ) -> (altitude: Double, azimuth: Double) {
        // Hour Angle
        var ha = lst - ra
        if ha < 0 { ha += 360 }
        if ha > 180 { ha -= 360 }

        let haRad = ha * .pi / 180.0
        let decRad = dec * .pi / 180.0
        let latRad = latitude * .pi / 180.0

        // Altitude
        let sinAlt = sin(decRad) * sin(latRad) + cos(decRad) * cos(latRad) * cos(haRad)
        let altitude = asin(max(-1, min(1, sinAlt))) * 180.0 / .pi

        // Azimuth
        let cosAz = (sin(decRad) - sin(altitude * .pi / 180.0) * sin(latRad)) /
                    (cos(altitude * .pi / 180.0) * cos(latRad))
        var azimuth = acos(max(-1, min(1, cosAz))) * 180.0 / .pi

        if sin(haRad) > 0 {
            azimuth = 360.0 - azimuth
        }

        return (altitude, azimuth)
    }

    // MARK: - Visible Star Calculation

    /// Calculate visible stars for current time and location
    func calculateVisibleStars(
        date: Date,
        location: CLLocationCoordinate2D,
        viewSize: CGSize,
        horizonY: CGFloat
    ) -> [VisibleStar] {
        let lst = localSiderealTime(date: date, longitude: location.longitude)

        var visibleStars: [VisibleStar] = []

        for star in stars {
            let (altitude, azimuth) = equatorialToHorizontal(
                ra: star.ra,
                dec: star.dec,
                lst: lst,
                latitude: location.latitude
            )

            // Skip stars below horizon
            guard altitude > 0 else { continue }

            // Convert to screen position
            // Azimuth: 0 = North, 90 = East, 180 = South, 270 = West
            // Map to screen: full 360 degree view mapped to width
            let normalizedAz = azimuth / 360.0
            let x = normalizedAz * viewSize.width

            // Altitude: 0 = horizon, 90 = zenith
            // Map to screen: horizon at horizonY, zenith at top (0)
            let normalizedAlt = altitude / 90.0
            let y = horizonY * (1.0 - normalizedAlt)

            let screenPosition = CGPoint(x: x, y: y)

            visibleStars.append(VisibleStar(
                catalogStar: star,
                altitude: altitude,
                azimuth: azimuth,
                screenPosition: screenPosition
            ))
        }

        return visibleStars
    }

    /// Get all stars in catalog (for static rendering)
    var allStars: [CatalogStar] {
        stars
    }
}

// MARK: - JSON Catalog Format

struct StarCatalogFile: Codable {
    let epoch: Double?
    let stars: [CatalogStar]
}
