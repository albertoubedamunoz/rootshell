//
//  OpenInFolderPlacement.swift
//  rootshell
//

import Foundation

/// Where the new shell goes.
nonisolated enum OpenInFolderPlacement: String, CaseIterable, Codable, Sendable {
    case newTab
    case splitRight
    case splitDown
    case splitLeft
    case splitUp

    var title: String {
        switch self {
        case .newTab: return String(localized: "New Tab", comment: "Open in Folder placement")
        case .splitRight: return String(localized: "Split Right", comment: "Open in Folder placement")
        case .splitDown: return String(localized: "Split Down", comment: "Open in Folder placement")
        case .splitLeft: return String(localized: "Split Left", comment: "Open in Folder placement")
        case .splitUp: return String(localized: "Split Up", comment: "Open in Folder placement")
        }
    }

    var systemImage: String {
        switch self {
        case .newTab: return "plus.rectangle.on.rectangle"
        case .splitRight: return "rectangle.righthalf.inset.filled"
        case .splitDown: return "rectangle.bottomhalf.inset.filled"
        case .splitLeft: return "rectangle.lefthalf.inset.filled"
        case .splitUp: return "rectangle.tophalf.inset.filled"
        }
    }

    var isSplit: Bool { self != .newTab }

    /// Placements a target without left/up splits (herdr) can honour.
    static func available(supportsLeftUp: Bool) -> [OpenInFolderPlacement] {
        supportsLeftUp ? allCases : [.newTab, .splitRight, .splitDown]
    }
}
