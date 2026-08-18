import Foundation

/// WiFi frequency band classification
enum WiFiBand: String, Codable, Hashable, Sendable, Comparable {
    case band2_4 = "2.4 GHz"
    case band5 = "5 GHz"
    case band6 = "6 GHz"

    /// Short display name for badges: "2.4G", "5G", "6G"
    var shortName: String {
        switch self {
        case .band2_4: return "2.4G"
        case .band5: return "5G"
        case .band6: return "6G"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .band2_4: return 0
        case .band5: return 1
        case .band6: return 2
        }
    }

    static func < (lhs: WiFiBand, rhs: WiFiBand) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Derive band from frequency in GHz
    static func from(frequencyGHz: Double) -> WiFiBand {
        if frequencyGHz >= 5.925 {
            return .band6
        } else if frequencyGHz >= 3.0 {
            return .band5
        } else {
            return .band2_4
        }
    }
}
