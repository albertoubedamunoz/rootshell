import Foundation

/// A preference for the closed Duo's front display; inner-display layout is adaptive.
nonisolated enum DuoFrontDisplayMode: String, CaseIterable, Sendable {
    case sideRail
    case belowCamera
    case behindCamera

    var displayName: String {
        switch self {
        case .sideRail: String(localized: "Side Rail", comment: "Duo front display layout")
        case .belowCamera: String(localized: "Below Camera", comment: "Duo front display layout")
        case .behindCamera: String(localized: "Behind Camera", comment: "Duo front display layout")
        }
    }
}
